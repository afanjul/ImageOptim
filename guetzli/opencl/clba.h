// GPU (OpenCL) port of the hot parts of butteraugli.
//
// Design notes that the rest of this file assumes:
//
//  * On this class of hardware a clFinish round-trip costs ~221 us while
//    enqueuing a kernel costs ~3.5 us. So nothing here synchronises per
//    operation: a whole Diffmap is enqueued as one chain of kernels and the
//    caller synchronises exactly once, when it reads the result back.
//
//  * Apple GPUs have no cl_khr_fp64, so every kernel is fp32. butteraugli's
//    CPU code uses double for some intermediates; the ports use float and the
//    resulting deviation is measured by clba_test rather than assumed.
//
//  * Device planes are packed (stride == xsize), unlike ImageF which pads rows
//    to a cache line. Conversion happens only at the host boundary.

#ifndef CLBUTTERAUGLI_CLBA_H_
#define CLBUTTERAUGLI_CLBA_H_

#include <stddef.h>

#include <vector>

namespace clba {

// True if a usable OpenCL GPU was found. Safe to call from anywhere; the
// device is initialised once, on first call, and never re-probed.
bool Available();

// Human-readable reason Available() returned false (for diagnostics).
const char* UnavailableReason();

// A device-resident float plane, packed: element (x, y) lives at y*xsize + x.
// Copyable handles are deliberately not provided; planes are owned by a Ctx.
class Plane {
 public:
  Plane() : mem_(nullptr), xsize_(0), ysize_(0) {}
  ~Plane();
  Plane(Plane&& other);
  Plane& operator=(Plane&& other);

  void Alloc(size_t xsize, size_t ysize);
  bool empty() const { return mem_ == nullptr; }
  size_t xsize() const { return xsize_; }
  size_t ysize() const { return ysize_; }
  void* mem() const { return mem_; }

  // Host transfer. Both take a row-strided host buffer (stride in floats) so
  // they can talk to ImageF directly. Upload is asynchronous; Download
  // synchronises the queue.
  void Upload(const float* host, size_t host_stride);
  void Download(float* host, size_t host_stride) const;

 private:
  Plane(const Plane&);
  Plane& operator=(const Plane&);
  void* mem_;  // cl_mem
  size_t xsize_, ysize_;
};

// Blocks until every enqueued kernel has completed.
void Finish();

// ---------------------------------------------------------------------------
// Ported primitives. Each mirrors a butteraugli function of the same name and
// is bit-comparable against it (see clba_test).
// ---------------------------------------------------------------------------

// out = Blur(in, sigma, border_ratio). Scratch is taken from an internal
// per-size pool, so this is safe to call back to back. `in` and `out` may be
// the same plane.
void Blur(const Plane& in, float sigma, float border_ratio, Plane* out);

// Device-resident equivalent of butteraugli's PsychoImage. Keeping one of
// these alive across calls means the planes are allocated once, not 97 times.
struct Psycho {
  Plane lf[3], mf[3], hf[2], uhf[2];
};

// ps = SeparateFrequencies(xyb). Enqueues the whole decomposition -- 8 blurs
// and 7 pointwise passes -- without synchronising.
void SeparateFrequencies(const Plane xyb[3], Psycho* ps);

// diffmap += w * (i0 - i1)^2, and its asymmetric and noise-level siblings.
// All three accumulate into diffmap, as the CPU versions do.
void L2Diff(const Plane& i0, const Plane& i1, double w, Plane* diffmap);
void L2DiffAsymmetric(const Plane& i0, const Plane& i1, double w_0gt1,
                      double w_0lt1, Plane* diffmap);
void SameNoiseLevels(const Plane& i0, const Plane& i1, double kSigma, double w,
                     double maxclamp, Plane* diffmap);

// block_diff_ac += MaltaDiffMap(lum0, lum1). Accumulates, like the CPU
// version, so block_diff_ac must already hold the running sum.
void MaltaDiffMap(const Plane& lum0, const Plane& lum1, double w_0gt1,
                  double w_0lt1, double norm1, Plane* block_diff_ac);
void MaltaDiffMapLF(const Plane& lum0, const Plane& lum1, double w_0gt1,
                    double w_0lt1, double norm1, Plane* block_diff_ac);

// The masking stage. MaskPsychoImage mixes hf and uhf into the two channels
// Mask consumes, then Mask produces the six masking planes.
// Planes are passed as arrays of pointers, not arrays of Planes, so callers
// can hand over pooled planes they do not own.
void DiffPrecompute(const Plane& xyb0, const Plane& xyb1, Plane* out);
void Mask(const Plane* const xyb0[3], const Plane* const xyb1[3],
          Plane* mask[3], Plane* mask_dc[3]);
void MaskPsychoImage(const Psycho& pi0, const Psycho& pi1, Plane* mask[3],
                     Plane* mask_dc[3]);

// The two closing stages: fold the masks into the per-channel differences,
// then take the square root and spread it.
void CombineChannels(const Plane* const mask[3], const Plane* const mask_dc[3],
                     const Plane* const block_diff_dc[3],
                     const Plane* const block_diff_ac[3], Plane* result);
void CalculateDiffmap(const Plane& in, Plane* diffmap);

// The whole comparison: everything ButteraugliComparator::DiffmapPsychoImage
// does, enqueued without a single synchronisation.
void DiffmapPsychoImage(const Psycho& pi0, const Psycho& pi1, Plane* result);

// The gaussian kernel butteraugli would use for this sigma, for tests.
std::vector<float> ComputeKernel(float sigma);

// A single transposing convolution pass, exposed for tests so a divergence can
// be attributed to one pass rather than to the pair.
void ConvolutionPass(const Plane& in, float sigma, float border_ratio,
                     Plane* out);

}  // namespace clba

#endif  // CLBUTTERAUGLI_CLBA_H_
