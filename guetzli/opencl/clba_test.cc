// Stage-by-stage CPU-vs-GPU comparison for the butteraugli OpenCL port.
//
// Every ported primitive is run twice on identical input -- once through
// butteraugli's CPU code, once through clba -- and the two results are
// compared exactly. The point is to measure the divergence forced by fp32
// rather than to assume it is small.

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <algorithm>
#include <string>
#include <vector>

#include "butteraugli/butteraugli.h"
#include "opencl/clba.h"

namespace butteraugli {
ImageF Blur(const ImageF& in, float sigma, float border_ratio);
ImageF Convolution(const ImageF& in, const std::vector<float>& kernel,
                   float border_ratio);
std::vector<float> ComputeKernel(float sigma);
namespace testhooks {
void SeparateFrequencies(size_t xsize, size_t ysize,
                         const std::vector<ImageF>& xyb, PsychoImage& ps);
void MaltaDiffMap(bool lf, const ImageF& lum0, const ImageF& lum1,
                  size_t xsize, size_t ysize, double w_0gt1, double w_0lt1,
                  double norm1, ImageF* block_diff_ac);
void L2Diff(const ImageF& i0, const ImageF& i1, double w, ImageF* diffmap);
void L2DiffAsymmetric(const ImageF& i0, const ImageF& i1, double w_0gt1,
                      double w_0lt1, ImageF* diffmap);
void SameNoiseLevels(const ImageF& i0, const ImageF& i1, double kSigma,
                     double w, double maxclamp, ImageF* diffmap);
ImageF DiffPrecompute(const ImageF& xyb0, const ImageF& xyb1);
void Mask(const std::vector<ImageF>& xyb0, const std::vector<ImageF>& xyb1,
          std::vector<ImageF>* mask, std::vector<ImageF>* mask_dc);
void MaskPsychoImage(const PsychoImage& pi0, const PsychoImage& pi1,
                     size_t xsize, size_t ysize, std::vector<ImageF>* mask,
                     std::vector<ImageF>* mask_dc);
ImageF CalculateDiffmap(const ImageF& diffmap_in);
}  // namespace testhooks
}  // namespace butteraugli

namespace {

using butteraugli::ImageF;

double Now() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + 1e-9 * ts.tv_nsec;
}

// Deterministic pseudo-random image with structure at several scales, so the
// border paths, flat regions and high-contrast edges all get exercised.
ImageF MakeImage(size_t xsize, size_t ysize, unsigned seed) {
  ImageF img(xsize, ysize);
  unsigned s = seed * 2654435761u + 1;
  for (size_t y = 0; y < ysize; ++y) {
    float* row = img.Row(y);
    for (size_t x = 0; x < xsize; ++x) {
      s = s * 1664525u + 1013904223u;
      const float noise = (float)((s >> 8) & 0xffff) / 65535.0f - 0.5f;
      const float smooth = 20.0f * sinf(0.013f * x) * cosf(0.017f * y);
      const float edge = ((x / 37 + y / 41) % 2) ? 30.0f : -30.0f;
      row[x] = smooth + edge + 8.0f * noise;
    }
  }
  return img;
}

struct Stats {
  double max_abs = 0.0;
  double max_rel = 0.0;
  double max_ulp = 0.0;
  size_t exact = 0;
  size_t total = 0;
  size_t nan_or_inf = 0;
  double max_abs_at_x = 0, max_abs_at_y = 0;
};

Stats Compare(const ImageF& a, const ImageF& b) {
  Stats st;
  for (size_t y = 0; y < a.ysize(); ++y) {
    const float* ra = a.Row(y);
    const float* rb = b.Row(y);
    for (size_t x = 0; x < a.xsize(); ++x) {
      const double va = ra[x], vb = rb[x];
      ++st.total;
      if (!isfinite(va) || !isfinite(vb)) {
        ++st.nan_or_inf;
        continue;
      }
      if (ra[x] == rb[x]) {
        ++st.exact;
        continue;
      }
      const double d = fabs(va - vb);
      if (d > st.max_abs) {
        st.max_abs = d;
        st.max_abs_at_x = x;
        st.max_abs_at_y = y;
      }
      const double denom = std::max(fabs(va), fabs(vb));
      if (denom > 1e-20) st.max_rel = std::max(st.max_rel, d / denom);
      // ULP distance: how many representable floats separate the two values.
      int ea, eb;
      frexp(va, &ea);
      frexp(vb, &eb);
      const double ulp = ldexp(1.0, std::max(ea, eb) - 24);
      if (ulp > 0) st.max_ulp = std::max(st.max_ulp, d / ulp);
    }
  }
  return st;
}

// The percentage is printed alongside the raw count of differing pixels: at
// these sizes a handful of divergent pixels still rounds to "100.000%", and a
// handful is exactly what a port that is nearly-but-not-quite exact produces.
void Report(const char* what, const Stats& st) {
  const double pct = 100.0 * st.exact / (st.total ? st.total : 1);
  printf("  %-28s exact %7.3f%% (%zu differ)  max|d| %10.3e  ulp %5.1f%s\n",
         what, pct, st.total - st.exact - st.nan_or_inf, st.max_abs, st.max_ulp,
         st.nan_or_inf ? "  *** NON-FINITE ***" : "");
}

bool g_failed = false;

// Pure relative error is the wrong yardstick here: these planes contain
// values that legitimately pass through zero, where any absolute difference
// gives an unbounded ratio. Judge against the plane's own dynamic range.
void CheckTolerance(const char* what, const Stats& st, double range,
                    double limit) {
  if (st.nan_or_inf != 0 || st.max_abs > limit * range) {
    printf("  FAIL: %s: max|d| %.3e exceeds %.1e of range %.3g\n", what,
           st.max_abs, limit, range);
    g_failed = true;
  }
}

double Range(const ImageF& a) {
  double lo = 1e30, hi = -1e30;
  for (size_t y = 0; y < a.ysize(); ++y) {
    const float* r = a.Row(y);
    for (size_t x = 0; x < a.xsize(); ++x) {
      if (r[x] < lo) lo = r[x];
      if (r[x] > hi) hi = r[x];
    }
  }
  return hi - lo;
}

void TestBlur(size_t xsize, size_t ysize) {
  printf("Blur %zux%zu\n", xsize, ysize);
  const ImageF in = MakeImage(xsize, ysize, 7);

  // The sigma/border pairs butteraugli actually uses.
  struct Case {
    float sigma, border;
    const char* name;
  };
  const Case cases[] = {
      {1.2f, 0.0f, "opsin kSigma=1.2"},
      {7.46953768697f, -0.00457628248637f, "SeparateFreq lf"},
      {3.734768843485f, -0.271277366628f, "SeparateFreq mf"},
      {1.8673844217425f, 0.147068973249f, "SeparateFreq hf"},
      {10.6666499623f, 0.0f, "SameNoiseLevels"},
      {2.3770330432f, -0.0724948220913f, "Mask r0"},
      {9.04353323561f, -0.0724948220913f, "Mask r1"},
      {9.24456601467f, -0.0724948220913f, "Mask r2"},
      {1.72547472444f, 1.0f, "CalculateDiffmap"},
  };

  clba::Plane gin, gout;
  gin.Alloc(xsize, ysize);
  gin.Upload(in.Row(0), in.bytes_per_row() / sizeof(float));

  for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
    const Case& c = cases[i];
    const ImageF cpu = butteraugli::Blur(in, c.sigma, c.border);

    clba::Blur(gin, c.sigma, c.border, &gout);
    ImageF gpu(xsize, ysize);
    gout.Download(gpu.Row(0), gpu.bytes_per_row() / sizeof(float));

    const Stats st = Compare(cpu, gpu);
    char label[128];
    snprintf(label, sizeof(label), "%s (len %zu)", c.name,
             butteraugli::ComputeKernel(c.sigma).size());
    Report(label, st);
    CheckTolerance(label, st, Range(cpu), 1e-6);
  }
}

// Attributes divergence in a single convolution pass to border vs middle
// columns. Blur chains two passes, so a pass-1 border error smears into the
// pass-2 middle and the two become indistinguishable.
void TestConvPass(size_t xsize, size_t ysize, float sigma, float border_ratio) {
  const ImageF in = MakeImage(xsize, ysize, 7);
  const std::vector<float> kern = butteraugli::ComputeKernel(sigma);
  const int len = (int)kern.size();
  const int offset = len / 2;
  const int border1 = ((int)xsize <= offset) ? (int)xsize : offset;
  const int border2 = (int)xsize - offset;

  const ImageF cpu = butteraugli::Convolution(in, kern, border_ratio);

  clba::Plane gin, gout;
  gin.Alloc(xsize, ysize);
  gin.Upload(in.Row(0), in.bytes_per_row() / sizeof(float));
  clba::ConvolutionPass(gin, sigma, border_ratio, &gout);
  ImageF gpu(ysize, xsize);  // transposed
  gout.Download(gpu.Row(0), gpu.bytes_per_row() / sizeof(float));

  size_t bad_border = 0, n_border = 0, bad_middle = 0, n_middle = 0;
  double worst_middle = 0;
  for (size_t x = 0; x < xsize; ++x) {  // x indexes rows of the transposed out
    const bool is_border = ((int)x < border1 || (int)x >= border2);
    const float* rc = cpu.Row(x);
    const float* rg = gpu.Row(x);
    for (size_t y = 0; y < ysize; ++y) {
      const bool same = (rc[y] == rg[y]);
      if (is_border) {
        ++n_border;
        if (!same) ++bad_border;
      } else {
        ++n_middle;
        if (!same) ++bad_middle;
        if (!same) worst_middle = std::max(worst_middle, fabs((double)rc[y] - rg[y]));
      }
    }
  }
  printf("  1 pass len %2d  border cols %5.2f%% differ (%zu/%zu)   "
         "middle cols %5.2f%% differ (%zu/%zu, max|d| %.3e)\n",
         len, 100.0 * bad_border / (n_border ? n_border : 1), bad_border,
         n_border, 100.0 * bad_middle / (n_middle ? n_middle : 1), bad_middle,
         n_middle, worst_middle);
}

void TestSeparateFrequencies(size_t xsize, size_t ysize) {
  printf("SeparateFrequencies %zux%zu\n", xsize, ysize);
  std::vector<ImageF> xyb;
  for (int i = 0; i < 3; ++i) xyb.push_back(MakeImage(xsize, ysize, 3 + i));

  butteraugli::PsychoImage cpu;
  butteraugli::testhooks::SeparateFrequencies(xsize, ysize, xyb, cpu);

  clba::Plane gxyb[3];
  for (int i = 0; i < 3; ++i) {
    gxyb[i].Alloc(xsize, ysize);
    gxyb[i].Upload(xyb[i].Row(0), xyb[i].bytes_per_row() / sizeof(float));
  }
  clba::Psycho gpu;
  clba::SeparateFrequencies(gxyb, &gpu);
  clba::Finish();

  struct Out {
    const std::vector<ImageF>* cpu;
    clba::Plane* gpu;
    const char* name;
    int count;
  };
  const Out outs[] = {
      {&cpu.lf, gpu.lf, "lf", 3},
      {&cpu.mf, gpu.mf, "mf", 3},
      {&cpu.hf, gpu.hf, "hf", 2},
      {&cpu.uhf, gpu.uhf, "uhf", 2},
  };
  for (size_t o = 0; o < sizeof(outs) / sizeof(outs[0]); ++o) {
    for (int i = 0; i < outs[o].count; ++i) {
      ImageF got(xsize, ysize);
      outs[o].gpu[i].Download(got.Row(0), got.bytes_per_row() / sizeof(float));
      const Stats st = Compare((*outs[o].cpu)[i], got);
      char label[64];
      snprintf(label, sizeof(label), "%s[%d]", outs[o].name, i);
      Report(label, st);
      CheckTolerance(label, st, Range((*outs[o].cpu)[i]), 1e-6);
    }
  }
}

// The six MaltaDiffMap calls DiffmapPsychoImage makes. The weights are
// transcribed rather than shared, so they may differ from the production ones
// in the last bits; that is harmless, because what the comparison needs is
// only that both sides receive the same doubles. What does matter is the
// range: norm1 spans eight orders of magnitude here exactly as it does in
// DiffmapPsychoImage, and that is what stresses the double-float objectives.
struct MaltaCase {
  int plane;  // index into the flattened {uhf, hf, mf} sets below
  double w_0gt1, w_0lt1, norm1;
  bool lf;
  const char* name;
};

const MaltaCase kMaltaCases[] = {
    {0, 5.1409625726 * 0.8, 5.1409625726 / 0.8, 58.5001247061, false, "uhf[1]"},
    {1, 4.91743441556 * 0.8, 4.91743441556 / 0.8, 687196.39002, false,
     "uhf[0]"},
    {2, 153.671655716 * 0.894427190999916,
     153.671655716 / 0.894427190999916, 83150785.9592, true, "hf[1]"},
    {3, 668.358918152 * 0.894427190999916,
     668.358918152 / 0.894427190999916, 0.882954368025, true, "hf[0]"},
    {4, 6841.81248144, 6841.81248144, 0.0135134962487, true, "mf[1]"},
    {5, 813.901703816, 813.901703816, 16792.9322251, true, "mf[0]"},
};

// Real uhf/hf/mf planes rather than synthetic noise: the half-open objectives
// branch on the relation between the two inputs, so the input distribution is
// what decides which branches get exercised.
void MaltaInputs(size_t xsize, size_t ysize, std::vector<ImageF>* out) {
  butteraugli::PsychoImage p[2];
  for (int side = 0; side < 2; ++side) {
    std::vector<ImageF> xyb;
    for (int i = 0; i < 3; ++i) {
      xyb.push_back(MakeImage(xsize, ysize, (side ? 23 : 3) + i));
    }
    butteraugli::testhooks::SeparateFrequencies(xsize, ysize, xyb, p[side]);
  }
  for (int side = 0; side < 2; ++side) {
    out[side].clear();
    out[side].push_back(std::move(p[side].uhf[1]));
    out[side].push_back(std::move(p[side].uhf[0]));
    out[side].push_back(std::move(p[side].hf[1]));
    out[side].push_back(std::move(p[side].hf[0]));
    out[side].push_back(std::move(p[side].mf[1]));
    out[side].push_back(std::move(p[side].mf[0]));
  }
}

void TestMalta(size_t xsize, size_t ysize) {
  printf("MaltaDiffMap %zux%zu\n", xsize, ysize);
  std::vector<ImageF> in[2];
  MaltaInputs(xsize, ysize, in);

  // Both sides start from the same non-zero accumulator, so that the "+=" is
  // covered and not just the value being added.
  const ImageF init = MakeImage(xsize, ysize, 91);

  for (size_t i = 0; i < sizeof(kMaltaCases) / sizeof(kMaltaCases[0]); ++i) {
    const MaltaCase& c = kMaltaCases[i];
    const ImageF& l0 = in[0][c.plane];
    const ImageF& l1 = in[1][c.plane];

    ImageF cpu = butteraugli::CopyPixels(init);
    butteraugli::testhooks::MaltaDiffMap(c.lf, l0, l1, xsize, ysize, c.w_0gt1,
                                         c.w_0lt1, c.norm1, &cpu);

    clba::Plane g0, g1, gacc;
    g0.Alloc(xsize, ysize);
    g1.Alloc(xsize, ysize);
    gacc.Alloc(xsize, ysize);
    g0.Upload(l0.Row(0), l0.bytes_per_row() / sizeof(float));
    g1.Upload(l1.Row(0), l1.bytes_per_row() / sizeof(float));
    gacc.Upload(init.Row(0), init.bytes_per_row() / sizeof(float));
    if (c.lf) {
      clba::MaltaDiffMapLF(g0, g1, c.w_0gt1, c.w_0lt1, c.norm1, &gacc);
    } else {
      clba::MaltaDiffMap(g0, g1, c.w_0gt1, c.w_0lt1, c.norm1, &gacc);
    }
    ImageF gpu(xsize, ysize);
    gacc.Download(gpu.Row(0), gpu.bytes_per_row() / sizeof(float));

    const Stats st = Compare(cpu, gpu);
    char label[64];
    snprintf(label, sizeof(label), "%s %s norm1=%.3g", c.lf ? "LF" : "HF",
             c.name, c.norm1);
    Report(label, st);
    CheckTolerance(label, st, Range(cpu), 1e-6);
  }
}

// L2Diff, L2DiffAsymmetric and SameNoiseLevels, with the weights and the
// input planes DiffmapPsychoImage feeds them.
void TestL2(size_t xsize, size_t ysize) {
  printf("L2Diff / SameNoiseLevels %zux%zu\n", xsize, ysize);
  std::vector<ImageF> in[2];
  MaltaInputs(xsize, ysize, in);  // {uhf1, uhf0, hf1, hf0, mf1, mf0}
  const ImageF init = MakeImage(xsize, ysize, 91);

  struct Setup {
    int kind;  // 0 L2Diff, 1 L2DiffAsymmetric, 2 SameNoiseLevels
    int plane;
    double a, b;
    const char* name;
  };
  // wmul[1] is the only non-zero asymmetric weight; wmul[6] and wmul[8] are
  // the non-zero L2Diff ones. Zero weights take the early-out path, which is
  // covered here too so that the port's early-out matches.
  const Setup setups[] = {
      {1, 3, 32.4449876135 * 0.8, 32.4449876135 / 0.8, "L2DiffAsym hf[0]"},
      {1, 2, 0.0, 0.0, "L2DiffAsym hf[1] w=0"},
      {0, 5, 1.01370836411, 0, "L2Diff mf[0]"},
      {0, 4, 0.0, 0, "L2Diff mf[1] w=0"},
      {0, 5, 1.74566011615, 0, "L2Diff (lf weight)"},
      {2, 2, 884.809801415, 85.7047444518, "SameNoiseLevels hf[1]"},
  };

  for (size_t i = 0; i < sizeof(setups) / sizeof(setups[0]); ++i) {
    const Setup& s = setups[i];
    const ImageF& l0 = in[0][s.plane];
    const ImageF& l1 = in[1][s.plane];

    ImageF cpu = butteraugli::CopyPixels(init);
    clba::Plane g0, g1, gacc;
    g0.Alloc(xsize, ysize);
    g1.Alloc(xsize, ysize);
    gacc.Alloc(xsize, ysize);
    g0.Upload(l0.Row(0), l0.bytes_per_row() / sizeof(float));
    g1.Upload(l1.Row(0), l1.bytes_per_row() / sizeof(float));
    gacc.Upload(init.Row(0), init.bytes_per_row() / sizeof(float));

    if (s.kind == 0) {
      butteraugli::testhooks::L2Diff(l0, l1, s.a, &cpu);
      clba::L2Diff(g0, g1, s.a, &gacc);
    } else if (s.kind == 1) {
      butteraugli::testhooks::L2DiffAsymmetric(l0, l1, s.a, s.b, &cpu);
      clba::L2DiffAsymmetric(g0, g1, s.a, s.b, &gacc);
    } else {
      butteraugli::testhooks::SameNoiseLevels(l0, l1, 10.6666499623, s.a, s.b,
                                              &cpu);
      clba::SameNoiseLevels(g0, g1, 10.6666499623, s.a, s.b, &gacc);
    }
    ImageF gpu(xsize, ysize);
    gacc.Download(gpu.Row(0), gpu.bytes_per_row() / sizeof(float));

    const Stats st = Compare(cpu, gpu);
    Report(s.name, st);
    CheckTolerance(s.name, st, Range(cpu), 1e-6);
  }
}

void BenchMalta(size_t xsize, size_t ysize) {
  printf("MaltaDiffMap throughput %zux%zu (all 6 calls)\n", xsize, ysize);
  std::vector<ImageF> in[2];
  MaltaInputs(xsize, ysize, in);
  const int n = sizeof(kMaltaCases) / sizeof(kMaltaCases[0]);

  ImageF acc(xsize, ysize, 0.0);
  const int reps = 5;
  double t0 = Now();
  for (int r = 0; r < reps; ++r) {
    for (int i = 0; i < n; ++i) {
      const MaltaCase& c = kMaltaCases[i];
      butteraugli::testhooks::MaltaDiffMap(c.lf, in[0][c.plane], in[1][c.plane],
                                           xsize, ysize, c.w_0gt1, c.w_0lt1,
                                           c.norm1, &acc);
    }
  }
  const double t_cpu = (Now() - t0) / reps;

  std::vector<clba::Plane> g0(n), g1(n);
  clba::Plane gacc;
  gacc.Alloc(xsize, ysize);
  for (int i = 0; i < n; ++i) {
    const ImageF& a = in[0][kMaltaCases[i].plane];
    const ImageF& b = in[1][kMaltaCases[i].plane];
    g0[i].Alloc(xsize, ysize);
    g1[i].Alloc(xsize, ysize);
    g0[i].Upload(a.Row(0), a.bytes_per_row() / sizeof(float));
    g1[i].Upload(b.Row(0), b.bytes_per_row() / sizeof(float));
  }
  clba::Finish();

  t0 = Now();
  for (int r = 0; r < reps; ++r) {
    for (int i = 0; i < n; ++i) {
      const MaltaCase& c = kMaltaCases[i];
      if (c.lf) {
        clba::MaltaDiffMapLF(g0[i], g1[i], c.w_0gt1, c.w_0lt1, c.norm1, &gacc);
      } else {
        clba::MaltaDiffMap(g0[i], g1[i], c.w_0gt1, c.w_0lt1, c.norm1, &gacc);
      }
    }
  }
  clba::Finish();
  const double t_gpu = (Now() - t0) / reps;

  printf("  CPU %8.3f ms   GPU %8.3f ms   speedup %5.1fx\n", t_cpu * 1e3,
         t_gpu * 1e3, t_cpu / t_gpu);
}

void BenchBlur(size_t xsize, size_t ysize) {
  printf("Blur throughput %zux%zu (sigma 7.47, len %zu)\n", xsize, ysize,
         butteraugli::ComputeKernel(7.46953768697f).size());
  const ImageF in = MakeImage(xsize, ysize, 11);

  const int reps = 20;
  double t0 = Now();
  for (int i = 0; i < reps; ++i) {
    ImageF cpu = butteraugli::Blur(in, 7.46953768697f, -0.00457628248637f);
    if (cpu.Row(0)[0] == 12345.0f) printf("");  // defeat DCE
  }
  double t_cpu = (Now() - t0) / reps;

  clba::Plane gin, gout;
  gin.Alloc(xsize, ysize);
  gin.Upload(in.Row(0), in.bytes_per_row() / sizeof(float));
  clba::Blur(gin, 7.46953768697f, -0.00457628248637f, &gout);
  clba::Finish();

  t0 = Now();
  for (int i = 0; i < reps; ++i) {
    clba::Blur(gin, 7.46953768697f, -0.00457628248637f, &gout);
  }
  clba::Finish();
  double t_gpu = (Now() - t0) / reps;

  printf("  CPU %8.3f ms   GPU %8.3f ms   speedup %5.1fx\n", t_cpu * 1e3,
         t_gpu * 1e3, t_cpu / t_gpu);
}

// An 8-bit-ish RGB plane. MakeImage is centred on zero, which is not a
// meaningful input to OpsinDynamicsImage -- the gamma there expects 0..255.
ImageF MakeRgb(size_t xsize, size_t ysize, unsigned seed) {
  ImageF img = MakeImage(xsize, ysize, seed);
  for (size_t y = 0; y < ysize; ++y) {
    float* row = img.Row(y);
    for (size_t x = 0; x < xsize; ++x) {
      row[x] = std::min(255.0f, std::max(0.0f, 128.0f + 2.0f * row[x]));
    }
  }
  return img;
}

void UploadPsycho(const butteraugli::PsychoImage& src, clba::Psycho* dst) {
  const std::vector<ImageF>* in[4] = {&src.lf, &src.mf, &src.hf, &src.uhf};
  clba::Plane* out[4] = {dst->lf, dst->mf, dst->hf, dst->uhf};
  const int counts[4] = {3, 3, 2, 2};
  for (int o = 0; o < 4; ++o) {
    for (int i = 0; i < counts[o]; ++i) {
      const ImageF& p = (*in[o])[i];
      out[o][i].Alloc(p.xsize(), p.ysize());
      out[o][i].Upload(p.Row(0), p.bytes_per_row() / sizeof(float));
    }
  }
}

// The masking chain and the diffmap finaliser, isolated. TestDiffmap below
// exercises the same code, but a divergence there could come from any of six
// stages; these two say which.
void TestMaskStages(size_t xsize, size_t ysize) {
  printf("Mask / CalculateDiffmap %zux%zu\n", xsize, ysize);
  std::vector<ImageF> rgb0, rgb1;
  for (int i = 0; i < 3; ++i) {
    rgb0.push_back(MakeRgb(xsize, ysize, 11 + i));
    rgb1.push_back(MakeRgb(xsize, ysize, 21 + i));
  }
  butteraugli::PsychoImage pi0, pi1;
  butteraugli::testhooks::SeparateFrequencies(
      xsize, ysize, butteraugli::OpsinDynamicsImage(rgb0), pi0);
  butteraugli::testhooks::SeparateFrequencies(
      xsize, ysize, butteraugli::OpsinDynamicsImage(rgb1), pi1);

  clba::Psycho g0, g1;
  UploadPsycho(pi0, &g0);
  UploadPsycho(pi1, &g1);

  // DiffPrecompute on its own, on the two channels Mask feeds it.
  for (int ch = 0; ch < 2; ++ch) {
    const ImageF cpu =
        butteraugli::testhooks::DiffPrecompute(pi0.hf[ch], pi1.hf[ch]);
    clba::Plane out;
    clba::DiffPrecompute(g0.hf[ch], g1.hf[ch], &out);
    ImageF gpu(xsize, ysize);
    out.Download(gpu.Row(0), gpu.bytes_per_row() / sizeof(float));
    char label[64];
    snprintf(label, sizeof(label), "DiffPrecompute hf[%d]", ch);
    const Stats st = Compare(cpu, gpu);
    Report(label, st);
    CheckTolerance(label, st, Range(cpu), 1e-6);
  }

  // The six masking planes.
  std::vector<ImageF> cmask, cmask_dc;
  butteraugli::testhooks::MaskPsychoImage(pi0, pi1, xsize, ysize, &cmask,
                                          &cmask_dc);
  clba::Plane gm[3], gmdc[3];
  clba::Plane* pm[3];
  clba::Plane* pmdc[3];
  for (int i = 0; i < 3; ++i) {
    pm[i] = &gm[i];
    pmdc[i] = &gmdc[i];
  }
  clba::MaskPsychoImage(g0, g1, pm, pmdc);
  for (int i = 0; i < 6; ++i) {
    const ImageF& cpu = (i < 3) ? cmask[i] : cmask_dc[i - 3];
    ImageF gpu(xsize, ysize);
    (i < 3 ? gm[i] : gmdc[i - 3])
        .Download(gpu.Row(0), gpu.bytes_per_row() / sizeof(float));
    char label[64];
    snprintf(label, sizeof(label), "mask%s[%d]", i < 3 ? "" : "_dc", i % 3);
    const Stats st = Compare(cpu, gpu);
    Report(label, st);
    CheckTolerance(label, st, Range(cpu), 1e-6);
  }

  // CalculateDiffmap, fed a plane in the range CombineChannels produces:
  // non-negative, and straddling the 1e-4 threshold where the sqrt is
  // replaced by a linear ramp.
  ImageF in(xsize, ysize);
  for (size_t y = 0; y < ysize; ++y) {
    const float* src = cmask[1].Row(y);
    float* dst = in.Row(y);
    for (size_t x = 0; x < xsize; ++x) {
      dst[x] = (x % 7 == 0) ? 1e-5f * src[x] : src[x] * src[x];
    }
  }
  const ImageF cpu = butteraugli::testhooks::CalculateDiffmap(in);
  clba::Plane gin, gout;
  gin.Alloc(xsize, ysize);
  gin.Upload(in.Row(0), in.bytes_per_row() / sizeof(float));
  clba::CalculateDiffmap(gin, &gout);
  ImageF gpu(xsize, ysize);
  gout.Download(gpu.Row(0), gpu.bytes_per_row() / sizeof(float));
  const Stats st = Compare(cpu, gpu);
  Report("CalculateDiffmap", st);
  CheckTolerance("CalculateDiffmap", st, Range(cpu), 1e-6);
}

// The whole comparison, end to end. This is the only test that covers Mask,
// MaskPsychoImage, CombineChannels and CalculateDiffmap: butteraugli exposes
// no hook for them individually. It works because pi0_ is reproducible --
// it is exactly what SeparateFrequencies returns for OpsinDynamicsImage(rgb0),
// so the comparator and the GPU are fed the same first image.
void TestDiffmap(size_t xsize, size_t ysize) {
  printf("DiffmapPsychoImage %zux%zu\n", xsize, ysize);
  std::vector<ImageF> rgb0, rgb1;
  for (int i = 0; i < 3; ++i) {
    rgb0.push_back(MakeRgb(xsize, ysize, 11 + i));
    rgb1.push_back(MakeRgb(xsize, ysize, 21 + i));
  }

  butteraugli::ButteraugliComparator comparator(rgb0);
  butteraugli::PsychoImage pi0, pi1;
  butteraugli::testhooks::SeparateFrequencies(
      xsize, ysize, butteraugli::OpsinDynamicsImage(rgb0), pi0);
  butteraugli::testhooks::SeparateFrequencies(
      xsize, ysize, butteraugli::OpsinDynamicsImage(rgb1), pi1);

  ImageF cpu;
  comparator.DiffmapPsychoImage(pi1, cpu);

  clba::Psycho g0, g1;
  UploadPsycho(pi0, &g0);
  UploadPsycho(pi1, &g1);
  clba::Plane gres;
  clba::DiffmapPsychoImage(g0, g1, &gres);
  ImageF gpu(xsize, ysize);
  gres.Download(gpu.Row(0), gpu.bytes_per_row() / sizeof(float));

  // A diffmap of two unrelated images should be far from flat; if it were,
  // the comparison below would pass without having tested anything.
  const double range = Range(cpu);
  printf("  cpu diffmap range %.4g\n", range);
  if (range < 1e-3) {
    printf("  FAIL: diffmap is degenerate, the test proves nothing\n");
    g_failed = true;
  }
  const Stats st = Compare(cpu, gpu);
  Report("diffmap", st);
  CheckTolerance("diffmap", st, range, 1e-6);
}

void BenchDiffmap(size_t xsize, size_t ysize) {
  printf("Bench DiffmapPsychoImage %zux%zu\n", xsize, ysize);
  std::vector<ImageF> rgb0, rgb1;
  for (int i = 0; i < 3; ++i) {
    rgb0.push_back(MakeRgb(xsize, ysize, 11 + i));
    rgb1.push_back(MakeRgb(xsize, ysize, 21 + i));
  }
  butteraugli::ButteraugliComparator comparator(rgb0);
  butteraugli::PsychoImage pi0, pi1;
  butteraugli::testhooks::SeparateFrequencies(
      xsize, ysize, butteraugli::OpsinDynamicsImage(rgb0), pi0);
  butteraugli::testhooks::SeparateFrequencies(
      xsize, ysize, butteraugli::OpsinDynamicsImage(rgb1), pi1);

  const int reps = 5;
  ImageF cpu;
  comparator.DiffmapPsychoImage(pi1, cpu);  // warm up
  double t0 = Now();
  for (int i = 0; i < reps; ++i) comparator.DiffmapPsychoImage(pi1, cpu);
  const double t_cpu = (Now() - t0) / reps;

  clba::Psycho g0, g1;
  UploadPsycho(pi0, &g0);
  UploadPsycho(pi1, &g1);
  clba::Plane gres;
  clba::DiffmapPsychoImage(g0, g1, &gres);
  clba::Finish();
  t0 = Now();
  for (int i = 0; i < reps; ++i) clba::DiffmapPsychoImage(g0, g1, &gres);
  clba::Finish();
  const double t_gpu = (Now() - t0) / reps;

  printf("  CPU %8.3f ms   GPU %8.3f ms   speedup %5.1fx\n", t_cpu * 1e3,
         t_gpu * 1e3, t_cpu / t_gpu);
}

}  // namespace

int main(int argc, char** argv) {
  if (!clba::Available()) {
    printf("OpenCL unavailable: %s\n", clba::UnavailableReason());
    return 77;
  }

  // Sizes chosen to hit: the real working size, a size smaller than the
  // largest kernel radius (so every column is a border column), and odd
  // dimensions that stress the work-group padding.
  printf("Single convolution pass, 1024x781\n");
  TestConvPass(1024, 781, 1.2f, 0.0f);
  TestConvPass(1024, 781, 7.46953768697f, -0.00457628248637f);
  TestConvPass(1024, 781, 1.72547472444f, 1.0f);
  printf("\n");

  TestBlur(1024, 781);
  TestBlur(37, 23);
  TestBlur(8, 8);
  TestBlur(129, 1);
  printf("\n");
  TestSeparateFrequencies(1024, 781);
  TestSeparateFrequencies(37, 23);
  printf("\n");
  TestMalta(1024, 781);
  TestMalta(37, 23);
  printf("\n");
  TestL2(1024, 781);
  TestL2(64, 64);  // square, so a scratch-pool key collision would show up
  printf("\n");
  TestMaskStages(1024, 781);
  printf("\n");
  TestDiffmap(1024, 781);
  TestDiffmap(64, 64);
  printf("\n");
  BenchBlur(1024, 781);
  BenchMalta(1024, 781);
  BenchDiffmap(1024, 781);

  printf("\n%s\n", g_failed ? "FAILED" : "all stages within tolerance");
  return g_failed ? 1 : 0;
}
