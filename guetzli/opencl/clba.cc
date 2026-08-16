#include "opencl/clba.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <map>
#include <stdint.h>
#include <string>
#include <cmath>

#ifdef __APPLE__
#include <OpenCL/opencl.h>
#else
#include <CL/cl.h>
#endif

#include "opencl/clba_kernels.h"  // kCLBAKernelSource

// butteraugli computes its gaussian taps host-side; reuse that exact function
// so the kernel weights on the GPU are bit-identical to the CPU path rather
// than a re-derivation that might round differently.
namespace butteraugli {
std::vector<float> ComputeKernel(float sigma);
// Sampled at integer arguments to recover butteraugli's own mask LUTs; see
// MaskLuts below.
double MaskX(double delta);
double MaskY(double delta);
double MaskDcX(double delta);
double MaskDcY(double delta);
}

namespace clba {
namespace {

struct Ctx {
  bool ok = false;
  const char* reason = "not initialised";
  cl_platform_id platform = nullptr;
  cl_device_id device = nullptr;
  cl_context context = nullptr;
  cl_command_queue queue = nullptr;
  cl_program program = nullptr;
  std::map<std::string, cl_kernel> kernels;
  // Constant buffers for convolution taps, keyed by sigma. There are only a
  // handful of distinct sigmas in butteraugli and they repeat every call, so
  // caching them avoids re-uploading taps 26 times per Diffmap.
  struct Taps {
    cl_mem kern, skern;
    int len;
    float weight_no_border;
  };
  std::map<float, Taps> taps;
};

Ctx* g_ctx = nullptr;

bool Verbose() {
  static int v = -1;
  if (v < 0) v = getenv("CLBA_VERBOSE") != nullptr ? 1 : 0;
  return v != 0;
}

void Fail(Ctx* c, const char* why) {
  c->ok = false;
  c->reason = why;
  if (Verbose()) fprintf(stderr, "[clba] unavailable: %s\n", why);
}

// Reading the .cl from disk keeps the edit-run loop short during development;
// the embedded copy is what ships.
const char* KernelSource(std::string* storage) {
  const char* dir = getenv("CLBA_KERNEL_DIR");
  if (dir != nullptr) {
    std::string path = std::string(dir) + "/kernels_gen.cl";
    FILE* f = fopen(path.c_str(), "rb");
    if (f != nullptr) {
      char buf[65536];
      size_t n;
      while ((n = fread(buf, 1, sizeof(buf), f)) > 0) storage->append(buf, n);
      fclose(f);
      if (Verbose()) fprintf(stderr, "[clba] kernels from %s\n", path.c_str());
      return storage->c_str();
    }
  }
  return kCLBAKernelSource;
}

Ctx* Init() {
  if (g_ctx != nullptr) return g_ctx;
  g_ctx = new Ctx();
  Ctx* c = g_ctx;

  if (getenv("CLBA_DISABLE") != nullptr) {
    Fail(c, "disabled by CLBA_DISABLE");
    return c;
  }

  cl_uint n = 0;
  if (clGetPlatformIDs(1, &c->platform, &n) != CL_SUCCESS || n == 0) {
    Fail(c, "no OpenCL platform");
    return c;
  }
  if (clGetDeviceIDs(c->platform, CL_DEVICE_TYPE_GPU, 1, &c->device, &n) !=
          CL_SUCCESS ||
      n == 0) {
    Fail(c, "no OpenCL GPU device");
    return c;
  }
  cl_int err = CL_SUCCESS;
  c->context = clCreateContext(nullptr, 1, &c->device, nullptr, nullptr, &err);
  if (err != CL_SUCCESS) {
    Fail(c, "clCreateContext failed");
    return c;
  }
  c->queue = clCreateCommandQueue(c->context, c->device, 0, &err);
  if (err != CL_SUCCESS) {
    Fail(c, "clCreateCommandQueue failed");
    return c;
  }

  std::string storage;
  const char* src = KernelSource(&storage);
  c->program = clCreateProgramWithSource(c->context, 1, &src, nullptr, &err);
  if (err != CL_SUCCESS) {
    Fail(c, "clCreateProgramWithSource failed");
    return c;
  }
  // No -cl-fast-relaxed-math: reassociation would move results away from the
  // CPU reference for no useful speedup here.
  const char* opts = "-cl-std=CL1.2 -cl-fp32-correctly-rounded-divide-sqrt";
  err = clBuildProgram(c->program, 1, &c->device, opts, nullptr, nullptr);
  if (err != CL_SUCCESS) {
    size_t log_size = 0;
    clGetProgramBuildInfo(c->program, c->device, CL_PROGRAM_BUILD_LOG, 0,
                          nullptr, &log_size);
    std::string log(log_size, '\0');
    clGetProgramBuildInfo(c->program, c->device, CL_PROGRAM_BUILD_LOG, log_size,
                          &log[0], nullptr);
    fprintf(stderr, "[clba] kernel build failed:\n%s\n", log.c_str());
    Fail(c, "clBuildProgram failed");
    return c;
  }

  c->ok = true;
  c->reason = "ok";
  if (Verbose()) {
    char name[256] = {0};
    clGetDeviceInfo(c->device, CL_DEVICE_NAME, sizeof(name), name, nullptr);
    fprintf(stderr, "[clba] using %s\n", name);
  }
  return c;
}

cl_kernel Kernel(Ctx* c, const char* name) {
  std::map<std::string, cl_kernel>::iterator it = c->kernels.find(name);
  if (it != c->kernels.end()) return it->second;
  cl_int err = CL_SUCCESS;
  cl_kernel k = clCreateKernel(c->program, name, &err);
  if (err != CL_SUCCESS) {
    fprintf(stderr, "[clba] clCreateKernel(%s) failed: %d\n", name, err);
    abort();
  }
  c->kernels[name] = k;
  return k;
}

void Check(cl_int err, const char* what) {
  if (err != CL_SUCCESS) {
    fprintf(stderr, "[clba] %s failed: %d\n", what, err);
    abort();
  }
}

// butteraugli derives these three from the taps in float; do it identically
// rather than in double, so the middle-column path matches tap for tap.
const Ctx::Taps& GetTaps(Ctx* c, float sigma) {
  std::map<float, Ctx::Taps>::iterator it = c->taps.find(sigma);
  if (it != c->taps.end()) return it->second;

  std::vector<float> kern = butteraugli::ComputeKernel(sigma);
  const int len = static_cast<int>(kern.size());
  float weight_no_border = 0.0f;
  for (int j = 0; j < len; ++j) weight_no_border += kern[j];
  const float scale_no_border = 1.0f / weight_no_border;
  std::vector<float> skern(kern);
  for (int i = 0; i < len; ++i) skern[i] *= scale_no_border;

  cl_int err = CL_SUCCESS;
  Ctx::Taps t;
  t.len = len;
  t.weight_no_border = weight_no_border;
  t.kern = clCreateBuffer(c->context,
                          CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR,
                          len * sizeof(float), &kern[0], &err);
  Check(err, "clCreateBuffer(kern)");
  t.skern = clCreateBuffer(c->context,
                           CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR,
                           len * sizeof(float), &skern[0], &err);
  Check(err, "clCreateBuffer(skern)");
  c->taps[sigma] = t;
  return c->taps[sigma];
}

// One horizontal-convolve-and-transpose pass.
void ConvH(Ctx* c, const Plane& in, Plane* out, const Ctx::Taps& t,
           float border_ratio) {
  cl_kernel k = Kernel(c, "conv_h");
  cl_mem in_mem = (cl_mem)in.mem();
  cl_mem out_mem = (cl_mem)out->mem();
  const int xs = (int)in.xsize(), ys = (int)in.ysize();
  int a = 0;
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &in_mem), "arg0");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &out_mem), "arg1");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &t.kern), "arg2");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &t.skern), "arg3");
  Check(clSetKernelArg(k, a++, sizeof(int), &t.len), "arg4");
  Check(clSetKernelArg(k, a++, sizeof(int), &xs), "arg5");
  Check(clSetKernelArg(k, a++, sizeof(int), &ys), "arg6");
  Check(clSetKernelArg(k, a++, sizeof(float), &t.weight_no_border), "arg7");
  Check(clSetKernelArg(k, a++, sizeof(float), &border_ratio), "arg8");
  size_t lws[2] = {16, 16};
  size_t gws[2] = {((size_t)xs + 15) / 16 * 16, ((size_t)ys + 15) / 16 * 16};
  Check(clEnqueueNDRangeKernel(c->queue, k, 2, nullptr, gws, lws, 0, nullptr,
                               nullptr),
        "clEnqueueNDRangeKernel(conv_h)");
}

}  // namespace

bool Available() { return Init()->ok; }
const char* UnavailableReason() { return Init()->reason; }

void Finish() {
  Ctx* c = Init();
  if (c->ok) clFinish(c->queue);
}

Plane::~Plane() {
  if (mem_ != nullptr) clReleaseMemObject((cl_mem)mem_);
}

Plane::Plane(Plane&& other)
    : mem_(other.mem_), xsize_(other.xsize_), ysize_(other.ysize_) {
  other.mem_ = nullptr;
  other.xsize_ = other.ysize_ = 0;
}

Plane& Plane::operator=(Plane&& other) {
  if (this != &other) {
    if (mem_ != nullptr) clReleaseMemObject((cl_mem)mem_);
    mem_ = other.mem_;
    xsize_ = other.xsize_;
    ysize_ = other.ysize_;
    other.mem_ = nullptr;
    other.xsize_ = other.ysize_ = 0;
  }
  return *this;
}

void Plane::Alloc(size_t xsize, size_t ysize) {
  Ctx* c = Init();
  if (!c->ok) return;
  if (mem_ != nullptr && xsize_ == xsize && ysize_ == ysize) return;
  if (mem_ != nullptr) clReleaseMemObject((cl_mem)mem_);
  cl_int err = CL_SUCCESS;
  mem_ = clCreateBuffer(c->context, CL_MEM_READ_WRITE,
                        xsize * ysize * sizeof(float), nullptr, &err);
  Check(err, "clCreateBuffer(plane)");
  xsize_ = xsize;
  ysize_ = ysize;
}

void Plane::Upload(const float* host, size_t host_stride) {
  Ctx* c = Init();
  if (!c->ok || mem_ == nullptr) return;
  if (host_stride == xsize_) {
    Check(clEnqueueWriteBuffer(c->queue, (cl_mem)mem_, CL_FALSE, 0,
                               xsize_ * ysize_ * sizeof(float), host, 0,
                               nullptr, nullptr),
          "clEnqueueWriteBuffer");
    return;
  }
  const size_t origin[3] = {0, 0, 0};
  const size_t region[3] = {xsize_ * sizeof(float), ysize_, 1};
  Check(clEnqueueWriteBufferRect(c->queue, (cl_mem)mem_, CL_FALSE, origin,
                                 origin, region, xsize_ * sizeof(float), 0,
                                 host_stride * sizeof(float), 0, host, 0,
                                 nullptr, nullptr),
        "clEnqueueWriteBufferRect");
}

void Plane::Download(float* host, size_t host_stride) const {
  Ctx* c = Init();
  if (!c->ok || mem_ == nullptr) return;
  if (host_stride == xsize_) {
    Check(clEnqueueReadBuffer(c->queue, (cl_mem)mem_, CL_TRUE, 0,
                              xsize_ * ysize_ * sizeof(float), host, 0, nullptr,
                              nullptr),
          "clEnqueueReadBuffer");
    return;
  }
  const size_t origin[3] = {0, 0, 0};
  const size_t region[3] = {xsize_ * sizeof(float), ysize_, 1};
  Check(clEnqueueReadBufferRect(c->queue, (cl_mem)mem_, CL_TRUE, origin, origin,
                                region, xsize_ * sizeof(float), 0,
                                host_stride * sizeof(float), 0, host, 0,
                                nullptr, nullptr),
        "clEnqueueReadBufferRect");
}

std::vector<float> ComputeKernel(float sigma) {
  return butteraugli::ComputeKernel(sigma);
}

// Scratch buffers, pooled by (purpose, size). The queue is in-order, so one
// buffer per key is enough: the reader of a scratch plane has finished before
// the next writer of that same key starts. Never freed -- there are only ever
// a handful of distinct keys in a run.
//
// The purpose tag is not decoration. Without it a caller that needs its own
// scratch while calling Blur would collide with Blur's transposed
// intermediate whenever the plane happens to be square.
enum ScratchTag {
  kScratchBlur = 0,     // Blur's transposed intermediate
  kScratchMalta = 1,    // MaltaDiffMap's padded diffs
  kScratchNoise = 2,     // SameNoiseLevels' blurred plane
  kScratchMaskDiff = 3,  // Mask's DiffPrecompute output
  kScratchMaskBlur = 4,  // Mask's second Y-channel blur
  kScratchDiffmap = 5,   // CalculateDiffmap's blurred plane
  // DiffmapPsychoImage's working set. Each occupies a small range because it
  // is an array: block_diff_dc[3] then block_diff_ac[3], and so on.
  kScratchBlockDiff = 8,   // .. +5
  kScratchMask = 16,       // .. +5
  kScratchCombined = 24,
  kScratchMaskXyb = 32,    // .. +5, MaskPsychoImage's two mixed inputs
};

Plane& ScratchPlane(int tag, size_t xs, size_t ys) {
  static std::map<uint64_t, Plane>* pool = new std::map<uint64_t, Plane>();
  const uint64_t key = (static_cast<uint64_t>(tag) << 48) ^
                       (static_cast<uint64_t>(xs) << 24) ^ ys;
  Plane& p = (*pool)[key];
  p.Alloc(xs, ys);  // no-op once allocated at this size
  return p;
}

// Enqueue a kernel over n elements, one work-item each.
void Run1D(Ctx* c, cl_kernel k, size_t n) {
  const size_t lws = 256;
  const size_t gws = (n + lws - 1) / lws * lws;
  Check(clEnqueueNDRangeKernel(c->queue, k, 1, nullptr, &gws, &lws, 0, nullptr,
                               nullptr),
        "clEnqueueNDRangeKernel");
}

// Enqueue a kernel over an nx-by-ny grid, one work-item per element.
void Run2D(Ctx* c, cl_kernel k, size_t nx, size_t ny) {
  const size_t lws[2] = {16, 16};
  const size_t gws[2] = {(nx + 15) / 16 * 16, (ny + 15) / 16 * 16};
  Check(clEnqueueNDRangeKernel(c->queue, k, 2, nullptr, gws, lws, 0, nullptr,
                               nullptr),
        "clEnqueueNDRangeKernel");
}

// butteraugli writes `float_var *= some_double_constant` in a few places.
// Split the constant so the kernel can evaluate that product in double-float.
void SplitDouble(double k, float* hi, float* lo) {
  *hi = static_cast<float>(k);
  *lo = static_cast<float>(k - static_cast<double>(*hi));
}

void ConvolutionPass(const Plane& in, float sigma, float border_ratio,
                     Plane* out) {
  Ctx* c = Init();
  if (!c->ok) return;
  const Ctx::Taps& t = GetTaps(c, sigma);
  out->Alloc(in.ysize(), in.xsize());
  ConvH(c, in, out, t, border_ratio);
}

void Blur(const Plane& in, float sigma, float border_ratio, Plane* out) {
  Ctx* c = Init();
  if (!c->ok) return;
  const Ctx::Taps& t = GetTaps(c, sigma);
  const size_t xs = in.xsize(), ys = in.ysize();
  // Two transposing passes: xs*ys -> ys*xs -> xs*ys.
  Plane& mid = ScratchPlane(kScratchBlur, ys, xs);
  out->Alloc(xs, ys);
  ConvH(c, in, &mid, t, border_ratio);
  ConvH(c, mid, out, t, border_ratio);
}

void SeparateFrequencies(const Plane xyb[3], Psycho* ps) {
  Ctx* c = Init();
  if (!c->ok) return;
  const size_t xs = xyb[0].xsize(), ys = xyb[0].ysize();
  const int n = static_cast<int>(xs * ys);

  for (int i = 0; i < 3; ++i) ps->mf[i].Alloc(xs, ys);
  for (int i = 0; i < 2; ++i) ps->hf[i].Alloc(xs, ys);
  for (int i = 0; i < 2; ++i) ps->uhf[i].Alloc(xs, ys);

  // Constants, verbatim from SeparateFrequencies in butteraugli.cc.
  const float kSigmaLf = 7.46953768697f;
  const float kSigmaHf = 3.734768843485f;
  const float kSigmaUhf = 1.8673844217425f;
  const float border_lf = -0.00457628248637f;
  const float border_mf = -0.271277366628f;
  const float border_hf = 0.147068973249f;
  const float w0 = 0.120079806822f;
  const float w1 = 0.03430529365f;

  for (int i = 0; i < 3; ++i) {
    Blur(xyb[i], kSigmaLf, border_lf, &ps->lf[i]);

    // ... and keep everything else in mf.
    cl_kernel k = Kernel(c, "sf_sub");
    cl_mem a = (cl_mem)xyb[i].mem(), b = (cl_mem)ps->lf[i].mem();
    cl_mem o = (cl_mem)ps->mf[i].mem();
    Check(clSetKernelArg(k, 0, sizeof(cl_mem), &a), "sf_sub.0");
    Check(clSetKernelArg(k, 1, sizeof(cl_mem), &b), "sf_sub.1");
    Check(clSetKernelArg(k, 2, sizeof(cl_mem), &o), "sf_sub.2");
    Check(clSetKernelArg(k, 3, sizeof(int), &n), "sf_sub.3");
    Run1D(c, k, n);

    if (i == 2) {
      Blur(ps->mf[i], kSigmaHf, border_mf, &ps->mf[i]);
      break;
    }

    // Divide mf into mf and hf.
    Check(clEnqueueCopyBuffer(c->queue, (cl_mem)ps->mf[i].mem(),
                              (cl_mem)ps->hf[i].mem(), 0, 0,
                              n * sizeof(float), 0, nullptr, nullptr),
          "clEnqueueCopyBuffer(hf<-mf)");
    Blur(ps->mf[i], kSigmaHf, border_mf, &ps->mf[i]);

    cl_kernel k2 = Kernel(c, i == 0 ? "sf_hf_mf_x" : "sf_hf_mf_y");
    cl_mem hf = (cl_mem)ps->hf[i].mem(), mf = (cl_mem)ps->mf[i].mem();
    const float w = (i == 0) ? w0 : w1;
    Check(clSetKernelArg(k2, 0, sizeof(cl_mem), &hf), "sf_hf_mf.0");
    Check(clSetKernelArg(k2, 1, sizeof(cl_mem), &mf), "sf_hf_mf.1");
    Check(clSetKernelArg(k2, 2, sizeof(float), &w), "sf_hf_mf.2");
    Check(clSetKernelArg(k2, 3, sizeof(int), &n), "sf_hf_mf.3");
    Run1D(c, k2, n);
  }

  // Suppress red-green by intensity change in the high freq channels.
  {
    const double s = 0.745954517135;
    const double yw = 2.96534974403;  // `suppress`
    float s_hi, s_lo, yw_hi, yw_lo, ywms_hi, ywms_lo;
    SplitDouble(s, &s_hi, &s_lo);
    SplitDouble(yw, &yw_hi, &yw_lo);
    SplitDouble(yw * (1.0 - s), &ywms_hi, &ywms_lo);
    cl_kernel k = Kernel(c, "sf_suppress_x_by_y");
    cl_mem ix = (cl_mem)ps->hf[0].mem(), iy = (cl_mem)ps->hf[1].mem();
    int a = 0;
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &ix), "sxby.0");
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &iy), "sxby.1");
    Check(clSetKernelArg(k, a++, sizeof(float), &s_hi), "sxby.2");
    Check(clSetKernelArg(k, a++, sizeof(float), &s_lo), "sxby.3");
    Check(clSetKernelArg(k, a++, sizeof(float), &yw_hi), "sxby.4");
    Check(clSetKernelArg(k, a++, sizeof(float), &yw_lo), "sxby.5");
    Check(clSetKernelArg(k, a++, sizeof(float), &ywms_hi), "sxby.6");
    Check(clSetKernelArg(k, a++, sizeof(float), &ywms_lo), "sxby.7");
    Check(clSetKernelArg(k, a++, sizeof(int), &n), "sxby.8");
    Run1D(c, k, n);
  }

  const float kRemoveHfRange = 0.0287615200377f;
  const float kMaxclampHf = 78.8223237675f;
  const float kMaxclampUhf = 5.8907152736f;
  const float kMulSuppressHf = 1.10684769012f;
  const float kRegHf = 2000 * 0.478741530298f;
  const float kMulSuppressUhf = 1.76905001176f;
  const float kRegUhf = 2000 * 0.310148420674f;
  float kmul_hi, kmul_lo;
  SplitDouble(0.688059627878, &kmul_hi, &kmul_lo);  // MaximumClamp's kMul

  for (int i = 0; i < 2; ++i) {
    // Divide hf into hf and uhf.
    Check(clEnqueueCopyBuffer(c->queue, (cl_mem)ps->hf[i].mem(),
                              (cl_mem)ps->uhf[i].mem(), 0, 0,
                              n * sizeof(float), 0, nullptr, nullptr),
          "clEnqueueCopyBuffer(uhf<-hf)");
    Blur(ps->hf[i], kSigmaUhf, border_hf, &ps->hf[i]);

    cl_mem uhf = (cl_mem)ps->uhf[i].mem(), hf = (cl_mem)ps->hf[i].mem();
    if (i == 0) {
      cl_kernel k = Kernel(c, "sf_uhf_hf_x");
      Check(clSetKernelArg(k, 0, sizeof(cl_mem), &uhf), "uhfx.0");
      Check(clSetKernelArg(k, 1, sizeof(cl_mem), &hf), "uhfx.1");
      Check(clSetKernelArg(k, 2, sizeof(float), &kRemoveHfRange), "uhfx.2");
      Check(clSetKernelArg(k, 3, sizeof(int), &n), "uhfx.3");
      Run1D(c, k, n);
    } else {
      cl_kernel k = Kernel(c, "sf_uhf_hf_y");
      cl_mem lf1 = (cl_mem)ps->lf[1].mem();
      int a = 0;
      Check(clSetKernelArg(k, a++, sizeof(cl_mem), &uhf), "uhfy.0");
      Check(clSetKernelArg(k, a++, sizeof(cl_mem), &hf), "uhfy.1");
      Check(clSetKernelArg(k, a++, sizeof(cl_mem), &lf1), "uhfy.2");
      Check(clSetKernelArg(k, a++, sizeof(float), &kMaxclampHf), "uhfy.3");
      Check(clSetKernelArg(k, a++, sizeof(float), &kMaxclampUhf), "uhfy.4");
      Check(clSetKernelArg(k, a++, sizeof(float), &kmul_hi), "uhfy.5");
      Check(clSetKernelArg(k, a++, sizeof(float), &kmul_lo), "uhfy.6");
      Check(clSetKernelArg(k, a++, sizeof(float), &kMulSuppressHf), "uhfy.7");
      Check(clSetKernelArg(k, a++, sizeof(float), &kRegHf), "uhfy.8");
      Check(clSetKernelArg(k, a++, sizeof(float), &kMulSuppressUhf), "uhfy.9");
      Check(clSetKernelArg(k, a++, sizeof(float), &kRegUhf), "uhfy.10");
      Check(clSetKernelArg(k, a++, sizeof(int), &n), "uhfy.11");
      Run1D(c, k, n);
    }
  }

  // Convert low freq xyb to vals space.
  {
    const float xmul = 5.57547552483f, ymul = 1.20828034498f;
    const float bmul = 6.08319517575f, y_to_b_mul = -0.628811683685f;
    cl_kernel k = Kernel(c, "sf_xyb_low_freq_to_vals");
    cl_mem lx = (cl_mem)ps->lf[0].mem(), ly = (cl_mem)ps->lf[1].mem();
    cl_mem lb = (cl_mem)ps->lf[2].mem();
    int a = 0;
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &lx), "xyb.0");
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &ly), "xyb.1");
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &lb), "xyb.2");
    Check(clSetKernelArg(k, a++, sizeof(float), &xmul), "xyb.3");
    Check(clSetKernelArg(k, a++, sizeof(float), &ymul), "xyb.4");
    Check(clSetKernelArg(k, a++, sizeof(float), &bmul), "xyb.5");
    Check(clSetKernelArg(k, a++, sizeof(float), &y_to_b_mul), "xyb.6");
    Check(clSetKernelArg(k, a++, sizeof(int), &n), "xyb.7");
    Run1D(c, k, n);
  }
}

// Enqueue a kernel whose args are (in..., out, split w, n) -- the shape shared
// by l2diff and sq_accum.
void RunWeighted(Ctx* c, const char* name, const Plane* const* ins,
                 int n_ins,
                 double w, Plane* out) {
  cl_kernel k = Kernel(c, name);
  int a = 0;
  for (int i = 0; i < n_ins; ++i) {
    cl_mem m = (cl_mem)ins[i]->mem();
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &m), "in");
  }
  cl_mem out_mem = (cl_mem)out->mem();
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &out_mem), "out");
  float w_hi, w_lo;
  SplitDouble(w, &w_hi, &w_lo);
  Check(clSetKernelArg(k, a++, sizeof(float), &w_hi), "w_hi");
  Check(clSetKernelArg(k, a++, sizeof(float), &w_lo), "w_lo");
  const int n = (int)(out->xsize() * out->ysize());
  Check(clSetKernelArg(k, a++, sizeof(int), &n), "n");
  Run1D(c, k, n);
}

void L2Diff(const Plane& i0, const Plane& i1, double w, Plane* diffmap) {
  Ctx* c = Init();
  if (!c->ok || w == 0) return;  // the CPU returns early on w == 0
  const Plane* ins[2] = {&i0, &i1};
  RunWeighted(c, "l2diff", ins, 2, w, diffmap);
}

void L2DiffAsymmetric(const Plane& i0, const Plane& i1, double w_0gt1,
                      double w_0lt1, Plane* diffmap) {
  Ctx* c = Init();
  if (!c->ok) return;
  if (w_0gt1 == 0 && w_0lt1 == 0) return;  // as the CPU does
  w_0gt1 *= 0.8;
  w_0lt1 *= 0.8;

  cl_kernel k = Kernel(c, "l2diff_asym");
  cl_mem m0 = (cl_mem)i0.mem(), m1 = (cl_mem)i1.mem();
  cl_mem out_mem = (cl_mem)diffmap->mem();
  float wgt_hi, wgt_lo, wlt_hi, wlt_lo, small_hi, small_lo;
  SplitDouble(w_0gt1, &wgt_hi, &wgt_lo);
  SplitDouble(w_0lt1, &wlt_hi, &wlt_lo);
  SplitDouble(0.4, &small_hi, &small_lo);
  const int n = (int)(diffmap->xsize() * diffmap->ysize());
  int a = 0;
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &m0), "arg0");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &m1), "arg1");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &out_mem), "arg2");
  Check(clSetKernelArg(k, a++, sizeof(float), &wgt_hi), "arg3");
  Check(clSetKernelArg(k, a++, sizeof(float), &wgt_lo), "arg4");
  Check(clSetKernelArg(k, a++, sizeof(float), &wlt_hi), "arg5");
  Check(clSetKernelArg(k, a++, sizeof(float), &wlt_lo), "arg6");
  Check(clSetKernelArg(k, a++, sizeof(float), &small_hi), "arg7");
  Check(clSetKernelArg(k, a++, sizeof(float), &small_lo), "arg8");
  Check(clSetKernelArg(k, a++, sizeof(int), &n), "arg9");
  Run1D(c, k, n);
}

void SameNoiseLevels(const Plane& i0, const Plane& i1, double kSigma, double w,
                     double maxclamp, Plane* diffmap) {
  Ctx* c = Init();
  if (!c->ok) return;
  const size_t xs = i0.xsize(), ys = i0.ysize();
  Plane& tmp = ScratchPlane(kScratchNoise, xs, ys);

  cl_kernel k = Kernel(c, "noise_clamp");
  cl_mem m0 = (cl_mem)i0.mem(), m1 = (cl_mem)i1.mem();
  cl_mem tmp_mem = (cl_mem)tmp.mem();
  float mc_hi, mc_lo;
  SplitDouble(maxclamp, &mc_hi, &mc_lo);
  const int n = (int)(xs * ys);
  int a = 0;
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &m0), "arg0");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &m1), "arg1");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &tmp_mem), "arg2");
  Check(clSetKernelArg(k, a++, sizeof(float), &mc_hi), "arg3");
  Check(clSetKernelArg(k, a++, sizeof(float), &mc_lo), "arg4");
  Check(clSetKernelArg(k, a++, sizeof(int), &n), "arg5");
  Run1D(c, k, n);

  Blur(tmp, (float)kSigma, 0.0f, &tmp);
  const Plane* ins[1] = {&tmp};
  RunWeighted(c, "sq_accum", ins, 1, w, diffmap);
}

void DiffPrecompute(const Plane& xyb0, const Plane& xyb1, Plane* out) {
  Ctx* c = Init();
  if (!c->ok) return;
  const size_t xs = xyb0.xsize(), ys = xyb0.ysize();
  out->Alloc(xs, ys);
  const double mul0 = 0.918416534734;
  const double cutoff = 55.0184555849;
  float mul0_hi, mul0_lo, cut_hi, cut_lo;
  SplitDouble(mul0, &mul0_hi, &mul0_lo);
  SplitDouble(cutoff, &cut_hi, &cut_lo);
  cl_kernel k = Kernel(c, "diff_precompute");
  cl_mem m0 = (cl_mem)xyb0.mem(), m1 = (cl_mem)xyb1.mem();
  cl_mem out_mem = (cl_mem)out->mem();
  const int xsi = (int)xs, ysi = (int)ys;
  int a = 0;
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &m0), "arg0");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &m1), "arg1");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &out_mem), "arg2");
  Check(clSetKernelArg(k, a++, sizeof(int), &xsi), "arg3");
  Check(clSetKernelArg(k, a++, sizeof(int), &ysi), "arg4");
  Check(clSetKernelArg(k, a++, sizeof(float), &mul0_hi), "arg5");
  Check(clSetKernelArg(k, a++, sizeof(float), &mul0_lo), "arg6");
  Check(clSetKernelArg(k, a++, sizeof(float), &cut_hi), "arg7");
  Check(clSetKernelArg(k, a++, sizeof(float), &cut_lo), "arg8");
  Run2D(c, k, xs, ys);
}

// butteraugli's four mask LUTs, split into double-floats and uploaded once.
//
// The tables are recovered by sampling MaskX/MaskY/MaskDcX/MaskDcY at integer
// arguments rather than by re-running MakeMask here: at an integer the
// interpolator returns the table entry unchanged, so this is the real table
// and not a re-derivation that could drift from it.
struct MaskLutSet {
  cl_mem x, y, dcx, dcy;
};

const MaskLutSet& MaskLuts(Ctx* c) {
  static MaskLutSet* set = nullptr;
  if (set != nullptr) return *set;
  set = new MaskLutSet();

  typedef double (*Fn)(double);
  Fn fns[4] = {&butteraugli::MaskX, &butteraugli::MaskY, &butteraugli::MaskDcX,
               &butteraugli::MaskDcY};
  cl_mem* outs[4] = {&set->x, &set->y, &set->dcx, &set->dcy};
  for (int f = 0; f < 4; ++f) {
    float split[512 * 2];
    for (int i = 0; i < 512; ++i) {
      SplitDouble(fns[f]((double)i), &split[2 * i], &split[2 * i + 1]);
    }
    cl_int err = CL_SUCCESS;
    *outs[f] = clCreateBuffer(c->context,
                              CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR,
                              sizeof(split), split, &err);
    Check(err, "clCreateBuffer(mask lut)");
  }
  return *set;
}

void Mask(const Plane* const xyb0[3], const Plane* const xyb1[3],
          Plane* mask[3], Plane* mask_dc[3]) {
  Ctx* c = Init();
  if (!c->ok) return;
  const size_t xs = xyb0[0]->xsize(), ys = xyb0[0]->ysize();
  const int n = (int)(xs * ys);
  for (int i = 0; i < 3; ++i) {
    mask[i]->Alloc(xs, ys);
    mask_dc[i]->Alloc(xs, ys);
  }

  // Verbatim from Mask in butteraugli.cc.
  const double muls[2] = {0.207017089891, 0.267138152891};
  const double normalizer = 1.0 / (muls[0] + muls[1]);
  const double r0 = 2.3770330432;
  const double r1 = 9.04353323561;
  const double r2 = 9.24456601467;
  const double border_ratio = -0.0724948220913;

  Plane& diff = ScratchPlane(kScratchMaskDiff, xs, ys);
  Plane& b2 = ScratchPlane(kScratchMaskBlur, xs, ys);

  // X component: DiffPrecompute then one blur, straight into mask[0].
  DiffPrecompute(*xyb0[0], *xyb1[0], &diff);
  Blur(diff, (float)r2, (float)border_ratio, mask[0]);

  // Y component: the same precompute blurred at two radii and mixed.
  DiffPrecompute(*xyb0[1], *xyb1[1], &diff);
  Blur(diff, (float)r0, (float)border_ratio, mask[1]);
  Blur(diff, (float)r1, (float)border_ratio, &b2);
  {
    cl_kernel k = Kernel(c, "mask_y");
    cl_mem b1_mem = (cl_mem)mask[1]->mem(), b2_mem = (cl_mem)b2.mem();
    cl_mem out_mem = (cl_mem)mask[1]->mem();
    float m0_hi, m0_lo, m1_hi, m1_lo, nz_hi, nz_lo;
    SplitDouble(muls[0], &m0_hi, &m0_lo);
    SplitDouble(muls[1], &m1_hi, &m1_lo);
    SplitDouble(normalizer, &nz_hi, &nz_lo);
    int a = 0;
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &b1_mem), "arg0");
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &b2_mem), "arg1");
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &out_mem), "arg2");
    Check(clSetKernelArg(k, a++, sizeof(float), &m0_hi), "arg3");
    Check(clSetKernelArg(k, a++, sizeof(float), &m0_lo), "arg4");
    Check(clSetKernelArg(k, a++, sizeof(float), &m1_hi), "arg5");
    Check(clSetKernelArg(k, a++, sizeof(float), &m1_lo), "arg6");
    Check(clSetKernelArg(k, a++, sizeof(float), &nz_hi), "arg7");
    Check(clSetKernelArg(k, a++, sizeof(float), &nz_lo), "arg8");
    Check(clSetKernelArg(k, a++, sizeof(int), &n), "arg9");
    Run1D(c, k, n);
  }

  // B component, and the LUT lookups for all six planes.
  const double mul[2] = {16.6963293877, 2.1364621982};
  const double w00 = 36.4671237619;
  const double w11 = 2.1887170895;
  const double w_ytob_hf = 0.086624184478;
  const double w_ytob_lf = 21.6804277046;
  const double p1_to_p0 = 0.0513061271723;

  const MaskLutSet& luts = MaskLuts(c);
  cl_kernel k = Kernel(c, "mask_final");
  cl_mem m[3], dc[3];
  for (int i = 0; i < 3; ++i) {
    m[i] = (cl_mem)mask[i]->mem();
    dc[i] = (cl_mem)mask_dc[i]->mem();
  }
  float c0_hi, c0_lo, c1_hi, c1_lo, pp_hi, pp_lo, hf_hi, hf_lo, lf_hi, lf_lo;
  SplitDouble(mul[0] * w00, &c0_hi, &c0_lo);
  SplitDouble(mul[1] * w11, &c1_hi, &c1_lo);
  SplitDouble(p1_to_p0, &pp_hi, &pp_lo);
  SplitDouble(w_ytob_hf, &hf_hi, &hf_lo);
  SplitDouble(w_ytob_lf, &lf_hi, &lf_lo);
  int a = 0;
  for (int i = 0; i < 3; ++i) {
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &m[i]), "mask");
  }
  for (int i = 0; i < 3; ++i) {
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &dc[i]), "mask_dc");
  }
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &luts.x), "lut_x");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &luts.y), "lut_y");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &luts.dcx), "lut_dcx");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &luts.dcy), "lut_dcy");
  Check(clSetKernelArg(k, a++, sizeof(float), &c0_hi), "c0_hi");
  Check(clSetKernelArg(k, a++, sizeof(float), &c0_lo), "c0_lo");
  Check(clSetKernelArg(k, a++, sizeof(float), &c1_hi), "c1_hi");
  Check(clSetKernelArg(k, a++, sizeof(float), &c1_lo), "c1_lo");
  Check(clSetKernelArg(k, a++, sizeof(float), &pp_hi), "p1p0_hi");
  Check(clSetKernelArg(k, a++, sizeof(float), &pp_lo), "p1p0_lo");
  Check(clSetKernelArg(k, a++, sizeof(float), &hf_hi), "hf_hi");
  Check(clSetKernelArg(k, a++, sizeof(float), &hf_lo), "hf_lo");
  Check(clSetKernelArg(k, a++, sizeof(float), &lf_hi), "lf_hi");
  Check(clSetKernelArg(k, a++, sizeof(float), &lf_lo), "lf_lo");
  Check(clSetKernelArg(k, a++, sizeof(int), &n), "n");
  Run1D(c, k, n);
}

void MaskPsychoImage(const Psycho& pi0, const Psycho& pi1, Plane* mask[3],
                     Plane* mask_dc[3]) {
  Ctx* c = Init();
  if (!c->ok) return;
  const size_t xs = pi0.hf[0].xsize(), ys = pi0.hf[0].ysize();
  const int n = (int)(xs * ys);
  const double muls[4] = {0, 1.64178305129, 0.831081703362, 3.23680933546};

  // mask_xyb0/1 only ever hold two channels; the third is left as allocated,
  // and Mask never reads it.
  Plane* xyb0[3];
  Plane* xyb1[3];
  Plane** sides[2] = {xyb0, xyb1};
  const Psycho* pis[2] = {&pi0, &pi1};
  for (int side = 0; side < 2; ++side) {
    for (int i = 0; i < 3; ++i) {
      sides[side][i] = &ScratchPlane(kScratchMaskXyb + 3 * side + i, xs, ys);
    }
  }

  cl_kernel k = Kernel(c, "mask_pre");
  for (int i = 0; i < 2; ++i) {
    float a_hi, a_lo, b_hi, b_lo;
    SplitDouble(muls[2 * i], &a_hi, &a_lo);
    SplitDouble(muls[2 * i + 1], &b_hi, &b_lo);
    for (int side = 0; side < 2; ++side) {
      cl_mem uhf = (cl_mem)pis[side]->uhf[i].mem();
      cl_mem hf = (cl_mem)pis[side]->hf[i].mem();
      cl_mem out = (cl_mem)sides[side][i]->mem();
      int a = 0;
      Check(clSetKernelArg(k, a++, sizeof(cl_mem), &uhf), "arg0");
      Check(clSetKernelArg(k, a++, sizeof(cl_mem), &hf), "arg1");
      Check(clSetKernelArg(k, a++, sizeof(cl_mem), &out), "arg2");
      Check(clSetKernelArg(k, a++, sizeof(float), &a_hi), "arg3");
      Check(clSetKernelArg(k, a++, sizeof(float), &a_lo), "arg4");
      Check(clSetKernelArg(k, a++, sizeof(float), &b_hi), "arg5");
      Check(clSetKernelArg(k, a++, sizeof(float), &b_lo), "arg6");
      Check(clSetKernelArg(k, a++, sizeof(int), &n), "arg7");
      Run1D(c, k, n);
    }
  }
  Mask(xyb0, xyb1, mask, mask_dc);
}

void CombineChannels(const Plane* const mask[3], const Plane* const mask_dc[3],
                     const Plane* const block_diff_dc[3],
                     const Plane* const block_diff_ac[3], Plane* result) {
  Ctx* c = Init();
  if (!c->ok) return;
  const size_t xs = mask[0]->xsize(), ys = mask[0]->ysize();
  result->Alloc(xs, ys);
  const int n = (int)(xs * ys);
  cl_kernel k = Kernel(c, "combine_channels");
  const Plane* order[12] = {mask[0],          mask[1],
                            mask[2],          block_diff_dc[0],
                            block_diff_dc[1], block_diff_dc[2],
                            block_diff_ac[0], block_diff_ac[1],
                            block_diff_ac[2], mask_dc[0],
                            mask_dc[1],       mask_dc[2]};
  int a = 0;
  for (int i = 0; i < 12; ++i) {
    cl_mem mem = (cl_mem)order[i]->mem();
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &mem), "in");
  }
  cl_mem out_mem = (cl_mem)result->mem();
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &out_mem), "out");
  Check(clSetKernelArg(k, a++, sizeof(int), &n), "n");
  Run1D(c, k, n);
}

void CalculateDiffmap(const Plane& in, Plane* diffmap) {
  Ctx* c = Init();
  if (!c->ok) return;
  const size_t xs = in.xsize(), ys = in.ysize();
  const int n = (int)(xs * ys);
  diffmap->Alloc(xs, ys);

  {
    cl_kernel k = Kernel(c, "diffmap_sqrt");
    cl_mem in_mem = (cl_mem)in.mem(), out_mem = (cl_mem)diffmap->mem();
    int a = 0;
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &in_mem), "arg0");
    Check(clSetKernelArg(k, a++, sizeof(cl_mem), &out_mem), "arg1");
    Check(clSetKernelArg(k, a++, sizeof(int), &n), "arg2");
    Run1D(c, k, n);
  }

  const double kSigma = 1.72547472444;
  const double mul1 = 0.458794906198;
  const float scale = 1.0f / (1.0f + mul1);
  const double border_ratio = 1.0;

  Plane& blurred = ScratchPlane(kScratchDiffmap, xs, ys);
  Blur(*diffmap, (float)kSigma, (float)border_ratio, &blurred);

  cl_kernel k = Kernel(c, "diffmap_final");
  cl_mem dm = (cl_mem)diffmap->mem(), bl = (cl_mem)blurred.mem();
  float mul1_hi, mul1_lo;
  SplitDouble(mul1, &mul1_hi, &mul1_lo);
  int a = 0;
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &dm), "arg0");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &bl), "arg1");
  Check(clSetKernelArg(k, a++, sizeof(float), &mul1_hi), "arg2");
  Check(clSetKernelArg(k, a++, sizeof(float), &mul1_lo), "arg3");
  Check(clSetKernelArg(k, a++, sizeof(float), &scale), "arg4");
  Check(clSetKernelArg(k, a++, sizeof(int), &n), "arg5");
  Run1D(c, k, n);
}

// Shared body of MaltaDiffMap and MaltaDiffMapLF; `mulli` and `unit` are the
// only things that differ between them.
void MaltaDiffMapImpl(const Plane& lum0, const Plane& lum1, double w_0gt1,
                      double w_0lt1, double norm1, double mulli,
                      const char* unit, Plane* block_diff_ac) {
  Ctx* c = Init();
  if (!c->ok) return;
  const size_t xs = lum0.xsize(), ys = lum0.ysize();

  // Verbatim from MaltaDiffMapImpl in butteraugli.cc.
  const double len = 3.75;
  const float kWeight0 = 0.5;
  const float kWeight1 = 0.33;
  const double w_pre0gt1 = mulli * sqrt(kWeight0 * w_0gt1) / (len * 2 + 1);
  const double w_pre0lt1 = mulli * sqrt(kWeight1 * w_0lt1) / (len * 2 + 1);
  const float norm2_0gt1 = w_pre0gt1 * norm1;
  const float norm2_0lt1 = w_pre0lt1 * norm1;
  const float norm1f = static_cast<float>(norm1);

  // too_small = 0.55 * fabs0 and too_big = 1.05 * fabs0 are double products on
  // the CPU; the kernel redoes them in double-float from the split constants.
  float small_hi, small_lo, big_hi, big_lo;
  SplitDouble(0.55, &small_hi, &small_lo);
  SplitDouble(1.05, &big_hi, &big_lo);

  // diffs, inset by 4 pixels on every side so the stencil needs no clamping.
  const int pstride = static_cast<int>(xs) + 8;
  Plane& padded = ScratchPlane(kScratchMalta, pstride, ys + 8);

  const int xsi = static_cast<int>(xs), ysi = static_cast<int>(ys);
  cl_mem lum0_mem = (cl_mem)lum0.mem(), lum1_mem = (cl_mem)lum1.mem();
  cl_mem pad_mem = (cl_mem)padded.mem(), out_mem = (cl_mem)block_diff_ac->mem();

  cl_kernel k = Kernel(c, "malta_diffs");
  int a = 0;
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &lum0_mem), "arg0");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &lum1_mem), "arg1");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &pad_mem), "arg2");
  Check(clSetKernelArg(k, a++, sizeof(int), &xsi), "arg3");
  Check(clSetKernelArg(k, a++, sizeof(int), &ysi), "arg4");
  Check(clSetKernelArg(k, a++, sizeof(int), &pstride), "arg5");
  Check(clSetKernelArg(k, a++, sizeof(float), &norm1f), "arg6");
  Check(clSetKernelArg(k, a++, sizeof(float), &norm2_0gt1), "arg7");
  Check(clSetKernelArg(k, a++, sizeof(float), &norm2_0lt1), "arg8");
  Check(clSetKernelArg(k, a++, sizeof(float), &small_hi), "arg9");
  Check(clSetKernelArg(k, a++, sizeof(float), &small_lo), "arg10");
  Check(clSetKernelArg(k, a++, sizeof(float), &big_hi), "arg11");
  Check(clSetKernelArg(k, a++, sizeof(float), &big_lo), "arg12");
  Run2D(c, k, pstride, ys + 8);

  k = Kernel(c, unit);
  a = 0;
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &pad_mem), "arg0");
  Check(clSetKernelArg(k, a++, sizeof(cl_mem), &out_mem), "arg1");
  Check(clSetKernelArg(k, a++, sizeof(int), &xsi), "arg2");
  Check(clSetKernelArg(k, a++, sizeof(int), &ysi), "arg3");
  Check(clSetKernelArg(k, a++, sizeof(int), &pstride), "arg4");
  Run2D(c, k, xs, ys);
}

void MaltaDiffMap(const Plane& lum0, const Plane& lum1, double w_0gt1,
                  double w_0lt1, double norm1, Plane* block_diff_ac) {
  static const double mulli = 0.354191303559;
  MaltaDiffMapImpl(lum0, lum1, w_0gt1, w_0lt1, norm1, mulli, "malta_apply_hf",
                   block_diff_ac);
}

void MaltaDiffMapLF(const Plane& lum0, const Plane& lum1, double w_0gt1,
                    double w_0lt1, double norm1, Plane* block_diff_ac) {
  static const double mulli = 0.405371989604;
  MaltaDiffMapImpl(lum0, lum1, w_0gt1, w_0lt1, norm1, mulli, "malta_apply_lf",
                   block_diff_ac);
}

void DiffmapPsychoImage(const Psycho& pi0, const Psycho& pi1, Plane* result) {
  Ctx* c = Init();
  if (!c->ok) return;
  const size_t xs = pi0.hf[0].xsize(), ys = pi0.hf[0].ysize();
  if (xs < 8 || ys < 8) return;  // as the CPU does
  const int n = (int)(xs * ys);
  const float hf_asymmetry_ = 0.8f;

  // Everything below is pooled and reused: this runs about a hundred times
  // per guetzli encode, and allocating twelve planes each time would cost
  // more than the arithmetic.
  Plane* block_diff_dc[3];
  Plane* block_diff_ac[3];
  cl_kernel zero = Kernel(c, "fill_zero");
  for (int i = 0; i < 3; ++i) {
    block_diff_dc[i] = &ScratchPlane(kScratchBlockDiff + i, xs, ys);
    block_diff_ac[i] = &ScratchPlane(kScratchBlockDiff + 3 + i, xs, ys);
    for (int k = 0; k < 2; ++k) {
      cl_mem mem = (cl_mem)(k ? block_diff_ac[i] : block_diff_dc[i])->mem();
      Check(clSetKernelArg(zero, 0, sizeof(cl_mem), &mem), "arg0");
      Check(clSetKernelArg(zero, 1, sizeof(int), &n), "arg1");
      Run1D(c, zero, n);
    }
  }

  // Weights, verbatim from DiffmapPsychoImage in butteraugli.cc.
  const double wUhfMalta = 5.1409625726;
  const double norm1Uhf = 58.5001247061;
  MaltaDiffMap(pi0.uhf[1], pi1.uhf[1], wUhfMalta * hf_asymmetry_,
               wUhfMalta / hf_asymmetry_, norm1Uhf, block_diff_ac[1]);

  const double wUhfMaltaX = 4.91743441556;
  const double norm1UhfX = 687196.39002;
  MaltaDiffMap(pi0.uhf[0], pi1.uhf[0], wUhfMaltaX * hf_asymmetry_,
               wUhfMaltaX / hf_asymmetry_, norm1UhfX, block_diff_ac[0]);

  const double wHfMalta = 153.671655716;
  const double norm1Hf = 83150785.9592;
  MaltaDiffMapLF(pi0.hf[1], pi1.hf[1], wHfMalta * sqrt(hf_asymmetry_),
                 wHfMalta / sqrt(hf_asymmetry_), norm1Hf, block_diff_ac[1]);

  const double wHfMaltaX = 668.358918152;
  const double norm1HfX = 0.882954368025;
  MaltaDiffMapLF(pi0.hf[0], pi1.hf[0], wHfMaltaX * sqrt(hf_asymmetry_),
                 wHfMaltaX / sqrt(hf_asymmetry_), norm1HfX, block_diff_ac[0]);

  const double wMfMalta = 6841.81248144;
  const double norm1Mf = 0.0135134962487;
  MaltaDiffMapLF(pi0.mf[1], pi1.mf[1], wMfMalta, wMfMalta, norm1Mf,
                 block_diff_ac[1]);

  const double wMfMaltaX = 813.901703816;
  const double norm1MfX = 16792.9322251;
  MaltaDiffMapLF(pi0.mf[0], pi1.mf[0], wMfMaltaX, wMfMaltaX, norm1MfX,
                 block_diff_ac[0]);

  const double wmul[9] = {0, 32.4449876135, 0, 0, 0, 0,
                          1.01370836411, 0, 1.74566011615};

  const double maxclamp = 85.7047444518;
  const double kSigmaHfX = 10.6666499623;
  const double w = 884.809801415;
  SameNoiseLevels(pi0.hf[1], pi1.hf[1], kSigmaHfX, w, maxclamp,
                  block_diff_ac[1]);

  for (int i = 0; i < 3; ++i) {
    if (i < 2) {
      L2DiffAsymmetric(pi0.hf[i], pi1.hf[i], wmul[i] * hf_asymmetry_,
                       wmul[i] / hf_asymmetry_, block_diff_ac[i]);
    }
    L2Diff(pi0.mf[i], pi1.mf[i], wmul[3 + i], block_diff_ac[i]);
    L2Diff(pi0.lf[i], pi1.lf[i], wmul[6 + i], block_diff_dc[i]);
  }

  Plane* mask[3];
  Plane* mask_dc[3];
  for (int i = 0; i < 3; ++i) {
    mask[i] = &ScratchPlane(kScratchMask + i, xs, ys);
    mask_dc[i] = &ScratchPlane(kScratchMask + 3 + i, xs, ys);
  }
  MaskPsychoImage(pi0, pi1, mask, mask_dc);

  Plane& combined = ScratchPlane(kScratchCombined, xs, ys);
  CombineChannels(mask, mask_dc, block_diff_dc, block_diff_ac, &combined);
  CalculateDiffmap(combined, result);
}

}  // namespace clba
