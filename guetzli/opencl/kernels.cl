// OpenCL ports of butteraugli's hot functions.
//
// Every kernel here mirrors CPU code in butteraugli.cc. Where the CPU uses
// double for an intermediate, the port uses float (Apple GPUs have no fp64);
// where it uses float, the port reproduces the operation order exactly so the
// only divergence is that forced substitution.
//
// Planes are packed: element (x, y) of an xs-by-ys plane is at y*xs + x.
//
// FP_CONTRACT is off throughout. The CPU reference does not fuse its
// multiply-adds here, and letting the GPU fuse them drops bit-identical
// pixels from 97% to 50% for no measurable speedup.
#pragma OPENCL FP_CONTRACT OFF

// ---------------------------------------------------------------------------
// Convolution: horizontal convolution that transposes its output.
// Mirrors Convolution() + ConvolveBorderColumn() in butteraugli.cc.
//
// in  is xs by ys, out is ys by xs (transposed), so out[x*ys + y].
// kern is the raw kernel, skern the same kernel pre-divided by its sum -- both
// are computed host-side by butteraugli's own ComputeKernel so the taps are
// bit-identical to the CPU path.
// ---------------------------------------------------------------------------
__kernel void conv_h(__global const float* restrict in,
                     __global float* restrict out,
                     __constant float* restrict kern,
                     __constant float* restrict skern,
                     const int len, const int xs, const int ys,
                     const float weight_no_border, const float border_ratio) {
  const int x = get_global_id(0);
  const int y = get_global_id(1);
  if (x >= xs || y >= ys) return;

  const int offset = len / 2;
  const int border1 = (xs <= offset) ? xs : offset;
  const int border2 = xs - offset;

  float res;
  if (x < border1 || x >= border2) {
    // Border column: renormalise by the kernel mass that actually landed on
    // the image, interpolated towards the no-border mass by border_ratio.
    const int minx = (x < offset) ? 0 : x - offset;
    const int maxx = min(xs - 1, x + offset);
    float weight = 0.0f;
    for (int j = minx; j <= maxx; ++j) weight += kern[j - x + offset];
    weight = (1.0f - border_ratio) * weight + border_ratio * weight_no_border;
    const float scale = 1.0f / weight;
    __global const float* restrict row_in = in + (long)y * xs;
    float sum = 0.0f;
    for (int j = minx; j <= maxx; ++j) sum += row_in[j] * kern[j - x + offset];
    res = sum * scale;
  } else {
    const int d = x - offset;
    __global const float* restrict row_in = in + (long)y * xs + d;
    float sum = 0.0f;
    for (int j = 0; j < len; ++j) sum += row_in[j] * skern[j];
    res = sum;
  }
  out[(long)x * ys + y] = res;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// butteraugli mixes float variables with double constants, e.g. `v *= kMul`
// where v is float and kMul is double. That is a double-precision multiply
// rounded once to float, which a plain fp32 multiply does not reproduce. With
// the constant split as hi+lo (hi = (float)k, lo = (float)(k - hi)) this
// evaluates the product in double-float and rounds once, matching the CPU.
inline float mul_dk(float v, float hi, float lo) {
  const float p = v * hi;
  const float e = fma(v, hi, -p);
  return p + (e + v * lo);
}

// A double-float: a value represented as an unevaluated sum hi + lo with
// |lo| <= ulp(hi)/2. Gives ~48 bits of significand out of fp32 hardware, which
// is enough to reproduce butteraugli's double intermediates: what has to match
// is not the double itself but its single rounding down to float, and the
// double-float is wrong only when the exact result sits within 2^-48 of a
// float rounding boundary. mul_dk above is the two-operation special case.
//
// Every routine returns a normalised df, so df_cmp_f may assume normalisation.
typedef float2 df;

inline df df_quick_two_sum(float a, float b) {  // requires |a| >= |b|
  const float s = a + b;
  return (df)(s, b - (s - a));
}
inline df df_two_sum(float a, float b) {
  const float s = a + b;
  const float bb = s - a;
  return (df)(s, (a - (s - bb)) + (b - bb));
}
inline df df_two_prod(float a, float b) {
  const float p = a * b;
  return (df)(p, fma(a, b, -p));
}
inline df df_neg(df a) { return (df)(-a.x, -a.y); }
// a + b, where b is a plain float.
inline df df_add_f(df a, float b) {
  df s = df_two_sum(a.x, b);
  s.y += a.y;
  return df_quick_two_sum(s.x, s.y);
}
inline df df_add(df a, df b) {
  df s = df_two_sum(a.x, b.x);
  s.y += a.y + b.y;
  return df_quick_two_sum(s.x, s.y);
}
// a * b, where b is a plain float.
inline df df_mul_f(df a, float b) {
  df p = df_two_prod(a.x, b);
  p.y += a.y * b;
  return df_quick_two_sum(p.x, p.y);
}
inline df df_mul(df a, df b) {
  df p = df_two_prod(a.x, b.x);
  p.y += a.x * b.y + a.y * b.x;
  return df_quick_two_sum(p.x, p.y);
}
// The float nearest to a. Correct rounding relies on a being normalised.
inline float df_to_f(df a) { return a.x + a.y; }
// sign(a - b), for two dfs and for a df against a float.
inline int df_cmp(df a, df b) {
  if (a.x != b.x) return a.x < b.x ? -1 : 1;
  if (a.y != b.y) return a.y < b.y ? -1 : 1;
  return 0;
}
inline int df_cmp_f(df a, float b) {
  if (a.x != b) return a.x < b ? -1 : 1;
  return a.y < 0.0f ? -1 : (a.y > 0.0f ? 1 : 0);
}

// Make area around zero less important (remove it).
inline float RemoveRangeAroundZero(float w, float x) {
  return x > w ? x - w : (x < -w ? x + w : 0.0f);
}

// Make area around zero more important (2x it until the limit).
inline float AmplifyRangeAroundZero(float w, float x) {
  return x > w ? x + w : (x < -w ? x - w : 2.0f * x);
}

// ---------------------------------------------------------------------------
// SeparateFrequencies stages. Each mirrors one pointwise loop in the CPU
// function of that name; the blurs between them are conv_h pairs.
// ---------------------------------------------------------------------------

__kernel void fill_zero(__global float* restrict p, const int n) {
  const int i = get_global_id(0);
  if (i < n) p[i] = 0.0f;
}

// mf = xyb - lf
__kernel void sf_sub(__global const float* restrict a,
                     __global const float* restrict b,
                     __global float* restrict out, const int n) {
  const int i = get_global_id(0);
  if (i < n) out[i] = a[i] - b[i];
}

// i == 0: hf -= mf, then mf = RemoveRangeAroundZero(w0, mf)
__kernel void sf_hf_mf_x(__global float* restrict hf,
                         __global float* restrict mf, const float w0,
                         const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const float m = mf[i];
  hf[i] = hf[i] - m;
  mf[i] = RemoveRangeAroundZero(w0, m);
}

// i == 1: hf -= mf, then mf = AmplifyRangeAroundZero(w1, mf)
__kernel void sf_hf_mf_y(__global float* restrict hf,
                         __global float* restrict mf, const float w1,
                         const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const float m = mf[i];
  hf[i] = hf[i] - m;
  mf[i] = AmplifyRangeAroundZero(w1, m);
}

// Suppress red-green by intensity change in the high freq channels.
// The CPU evaluates this whole expression in double, so the port carries the
// two divisions in double-float: s and yw are split constants.
__kernel void sf_suppress_x_by_y(__global float* restrict ix,
                                 __global const float* restrict iy,
                                 const float s_hi, const float s_lo,
                                 const float yw_hi, const float yw_lo,
                                 const float ywms_hi, const float ywms_lo,
                                 const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const float yval = iy[i];
  // denom = yw + yval*yval, evaluated in double-float.
  const float sq = yval * yval;
  const float sq_e = fma(yval, yval, -sq);
  float dh = yw_hi + sq;
  const float dbig = (fabs(yw_hi) >= fabs(sq)) ? yw_hi : sq;
  const float dsml = (fabs(yw_hi) >= fabs(sq)) ? sq : yw_hi;
  float dl = (dbig - dh) + dsml + yw_lo + sq_e;
  // q = (yw*(1-s)) / denom
  const float q = ywms_hi / dh;
  const float qr = fma(-q, dh, ywms_hi) + (ywms_lo - q * dl);
  const float ql = qr / dh;
  // scaler = s + q
  float sh = s_hi + q;
  const float sbig = (fabs(s_hi) >= fabs(q)) ? s_hi : q;
  const float ssml = (fabs(s_hi) >= fabs(q)) ? q : s_hi;
  const float sl = (sbig - sh) + ssml + s_lo + ql;
  // result = scaler * xval, rounded once.
  const float xval = ix[i];
  const float p = sh * xval;
  const float pe = fma(sh, xval, -p);
  ix[i] = p + (pe + sl * xval);
}

// i == 0: uhf -= hf, then hf = RemoveRangeAroundZero(kRemoveHfRange, hf)
__kernel void sf_uhf_hf_x(__global float* restrict uhf,
                          __global float* restrict hf, const float range,
                          const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const float h = hf[i];
  uhf[i] = uhf[i] - h;
  hf[i] = RemoveRangeAroundZero(range, h);
}

// i == 1: uhf -= hf, clamp both, then suppress both by lf[1] brightness.
__kernel void sf_uhf_hf_y(__global float* restrict uhf,
                          __global float* restrict hf,
                          __global const float* restrict lf1,
                          const float maxclamp_hf, const float maxclamp_uhf,
                          const float kmul_hi, const float kmul_lo,
                          const float mul_suppress_hf, const float reg_hf,
                          const float mul_suppress_uhf, const float reg_uhf,
                          const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const float h0 = hf[i];
  float u = uhf[i] - h0;

  // MaximumClamp(v, maxval): the `v *= kMul` inside is a double multiply.
  float h = h0;
  if (h >= maxclamp_hf) {
    h = mul_dk(h - maxclamp_hf, kmul_hi, kmul_lo) + maxclamp_hf;
  } else if (h < -maxclamp_hf) {
    h = mul_dk(h + maxclamp_hf, kmul_hi, kmul_lo) - maxclamp_hf;
  }
  if (u >= maxclamp_uhf) {
    u = mul_dk(u - maxclamp_uhf, kmul_hi, kmul_lo) + maxclamp_uhf;
  } else if (u < -maxclamp_uhf) {
    u = mul_dk(u + maxclamp_uhf, kmul_hi, kmul_lo) - maxclamp_uhf;
  }

  const float brightness = lf1[i];
  // Suppress{Uhf,Hf}InBrightAreas are float throughout on the CPU.
  uhf[i] = (mul_suppress_uhf * reg_uhf / (reg_uhf + brightness)) * u;
  hf[i] = (mul_suppress_hf * reg_hf / (reg_hf + brightness)) * h;
}

// Convert low freq xyb to vals space. Float throughout on the CPU (the
// template is instantiated with V = float).
__kernel void sf_xyb_low_freq_to_vals(__global float* restrict lx,
                                      __global float* restrict ly,
                                      __global float* restrict lb,
                                      const float xmul, const float ymul,
                                      const float bmul, const float y_to_b_mul,
                                      const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const float y = ly[i];
  const float b = lb[i] + y_to_b_mul * y;
  lb[i] = b * bmul;
  lx[i] = lx[i] * xmul;
  ly[i] = y * ymul;
}

// ---------------------------------------------------------------------------
// MaltaDiffMap / MaltaDiffMapLF. Mirrors MaltaDiffMapImpl in butteraugli.cc,
// split into its two natural passes: build the diffs plane, then run the 9x9
// stencil over it.
// ---------------------------------------------------------------------------

// Pass 1: diffs. The CPU keeps too_small/too_big/impact in double, so the
// half-open objectives are carried in double-float here; the symmetric part is
// float on both sides.
//
// The output is written into a plane inset by 4 pixels on every side, and this
// kernel runs over the whole padded plane so the border is zeroed in the same
// launch. That border is what lets pass 2 drop PaddedMaltaUnit's bounds-check:
// reading zeros from the padding is exactly what the CPU's zero-filled
// borderimage produces.
__kernel void malta_diffs(__global const float* restrict lum0,
                          __global const float* restrict lum1,
                          __global float* restrict padded, const int xs,
                          const int ys, const int pstride,
                          const float norm1, const float norm2_0gt1,
                          const float norm2_0lt1, const float small_hi,
                          const float small_lo, const float big_hi,
                          const float big_lo) {
  const int px = get_global_id(0);
  const int py = get_global_id(1);
  if (px >= pstride || py >= ys + 8) return;
  const int x = px - 4;
  const int y = py - 4;
  if (x < 0 || y < 0 || x >= xs || y >= ys) {
    padded[(long)py * pstride + px] = 0.0f;
    return;
  }

  const int ix = y * xs + x;
  const float v0 = lum0[ix];
  const float v1 = lum1[ix];
  const float absval = 0.5f * fabs(v0) + 0.5f * fabs(v1);
  const float diff = v0 - v1;
  const float scaler = norm2_0gt1 / (norm1 + absval);

  // Primary symmetric quadratic objective.
  float res = scaler * diff;

  const float scaler2 = norm2_0lt1 / (norm1 + absval);
  const float fabs0 = fabs(v0);
  const df too_small = df_mul_f((df)(small_hi, small_lo), fabs0);
  const df too_big = df_mul_f((df)(big_hi, big_lo), fabs0);

  // Secondary half-open quadratic objectives.
  df impact;
  int have = 0;
  if (v0 < 0.0f) {
    if (df_cmp_f(df_neg(too_small), v1) < 0) {
      impact = df_mul_f(df_add_f(too_small, v1), scaler2);
      have = 1;
    } else if (df_cmp_f(df_neg(too_big), v1) > 0) {
      impact = df_mul_f(df_neg(df_add_f(too_big, v1)), scaler2);
      have = 1;
    }
  } else {
    if (df_cmp_f(too_small, v1) > 0) {
      impact = df_mul_f(df_add_f(too_small, -v1), scaler2);
      have = 1;
    } else if (df_cmp_f(too_big, v1) < 0) {
      impact = df_mul_f(df_neg(df_add_f(too_big, -v1)), scaler2);
      have = 1;
    }
  }
  if (have) {
    // float -= double on the CPU: widen, subtract, round once.
    const df acc = df_add_f(diff < 0.0f ? df_neg(impact) : impact, res);
    res = df_to_f(acc);
  }
  padded[(long)py * pstride + px] = res;
}

// The two MaltaUnit overloads, lifted from butteraugli.cc.
@MALTA_UNITS@

// Pass 2: accumulate the stencil into block_diff_ac. `padded` is inset by 4
// pixels on every side, so d never leaves the buffer and no bounds-check is
// needed -- see malta_diffs.
__kernel void malta_apply_hf(__global const float* restrict padded,
                             __global float* restrict out, const int xs,
                             const int ys, const int pstride) {
  const int x = get_global_id(0);
  const int y = get_global_id(1);
  if (x >= xs || y >= ys) return;
  __global const float* restrict d = padded + (long)(y + 4) * pstride + x + 4;
  out[(long)y * xs + x] += malta_unit_hf(d, pstride);
}

__kernel void malta_apply_lf(__global const float* restrict padded,
                             __global float* restrict out, const int xs,
                             const int ys, const int pstride) {
  const int x = get_global_id(0);
  const int y = get_global_id(1);
  if (x >= xs || y >= ys) return;
  __global const float* restrict d = padded + (long)(y + 4) * pstride + x + 4;
  out[(long)y * xs + x] += malta_unit_lf(d, pstride);
}

// ---------------------------------------------------------------------------
// L2Diff, L2DiffAsymmetric and SameNoiseLevels. These three are double from
// end to end on the CPU -- the inputs are floats but every intermediate is a
// double -- so they are double-float from end to end here.
//
// Association matters and is preserved: `w * diff * diff` is (w*diff)*diff,
// two roundings, not one. So is the accumulation: `row_diff[x] += ...` rounds
// to float once per statement, so a pixel that takes both the primary and a
// secondary objective in L2DiffAsymmetric rounds twice, in that order.
// ---------------------------------------------------------------------------

// out += w * diff * diff, with diff = i0 - i1.
__kernel void l2diff(__global const float* restrict i0,
                     __global const float* restrict i1,
                     __global float* restrict out, const float w_hi,
                     const float w_lo, const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const float diff = i0[i] - i1[i];
  df t = df_mul_f((df)(w_hi, w_lo), diff);
  t = df_mul_f(t, diff);
  out[i] = df_to_f(df_add_f(t, out[i]));
}

// out += w * in * in. The tail of SameNoiseLevels, after the blur.
__kernel void sq_accum(__global const float* restrict in,
                       __global float* restrict out, const float w_hi,
                       const float w_lo, const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const float diff = in[i];
  df t = df_mul_f((df)(w_hi, w_lo), diff);
  t = df_mul_f(t, diff);
  out[i] = df_to_f(df_add_f(t, out[i]));
}

// too_big is 1.0 * fabs0 on the CPU, i.e. exactly fabs0, so only too_small
// needs the split constant.
__kernel void l2diff_asym(__global const float* restrict i0,
                          __global const float* restrict i1,
                          __global float* restrict out, const float wgt_hi,
                          const float wgt_lo, const float wlt_hi,
                          const float wlt_lo, const float small_hi,
                          const float small_lo, const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const float v0 = i0[i], v1 = i1[i];

  // Primary symmetric quadratic objective.
  const float diff = v0 - v1;
  df t = df_mul_f((df)(wgt_hi, wgt_lo), diff);
  t = df_mul_f(t, diff);
  float acc = df_to_f(df_add_f(t, out[i]));

  // Secondary half-open quadratic objectives.
  const float fabs0 = fabs(v0);
  const df too_small = df_mul_f((df)(small_hi, small_lo), fabs0);
  const df too_big = (df)(fabs0, 0.0f);
  df v;
  int have = 0;
  if (v0 < 0.0f) {
    if (df_cmp_f(df_neg(too_small), v1) < 0) {
      v = df_add_f(too_small, v1);
      have = 1;
    } else if (df_cmp_f(df_neg(too_big), v1) > 0) {
      v = df_neg(df_add_f(too_big, v1));
      have = 1;
    }
  } else {
    if (df_cmp_f(too_small, v1) > 0) {
      v = df_add_f(too_small, -v1);
      have = 1;
    } else if (df_cmp_f(too_big, v1) < 0) {
      v = df_neg(df_add_f(too_big, -v1));
      have = 1;
    }
  }
  if (have) {
    df u = df_mul((df)(wlt_hi, wlt_lo), v);
    u = df_mul(u, v);
    acc = df_to_f(df_add_f(u, acc));
  }
  out[i] = acc;
}

// ---------------------------------------------------------------------------
// Mask, and the pointwise stages around it. Double from end to end on the CPU
// again, including the 512-entry lookup tables, which arrive here as split
// double-floats (see MaskLuts in clba.cc).
// ---------------------------------------------------------------------------

// The integer part of a non-negative df. trunc(a.x) is the answer except when
// a.x is exactly integral and a.y pulls the value below it: |a.y| <= ulp(a.x)/2
// is too small to carry a.x across an integer boundary any other way.
inline int df_trunc_nonneg(df a) {
  int b = (int)a.x;
  if (a.y < 0.0f && (float)b == a.x) --b;
  return b;
}

// InterpolateClampNegative over a df-valued table.
inline df mask_lut(__global const float2* restrict lut, int size, df ix) {
  if (ix.x < 0.0f || (ix.x == 0.0f && ix.y < 0.0f)) ix = (df)(0.0f, 0.0f);
  const int baseix = df_trunc_nonneg(ix);
  if (baseix >= size - 1) return lut[size - 1];
  const df mix = df_add_f(ix, -(float)baseix);
  const df lo = lut[baseix];
  const df d = df_add(lut[baseix + 1], df_neg(lo));
  return df_add(lo, df_mul(mix, d));
}

// MaskPsychoImage's pre-pass: out = a*uhf + b*hf, for one of the two channels.
__kernel void mask_pre(__global const float* restrict uhf,
                       __global const float* restrict hf,
                       __global float* restrict out, const float a_hi,
                       const float a_lo, const float b_hi, const float b_lo,
                       const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const df t = df_mul_f((df)(a_hi, a_lo), uhf[i]);
  const df u = df_mul_f((df)(b_hi, b_lo), hf[i]);
  out[i] = df_to_f(df_add(t, u));
}

// DiffPrecompute. The neighbour is the next pixel, or the previous one at the
// far edge, or the pixel itself on a size-1 axis -- as on the CPU.
__kernel void diff_precompute(__global const float* restrict xyb0,
                              __global const float* restrict xyb1,
                              __global float* restrict out, const int xs,
                              const int ys, const float mul0_hi,
                              const float mul0_lo, const float cutoff_hi,
                              const float cutoff_lo) {
  const int x = get_global_id(0);
  const int y = get_global_id(1);
  if (x >= xs || y >= ys) return;
  const int x2 = (x + 1 < xs) ? x + 1 : (x > 0 ? x - 1 : x);
  const int y2 = (y + 1 < ys) ? y + 1 : (y > 0 ? y - 1 : y);
  const long i = (long)y * xs + x;
  const long ix2 = (long)y * xs + x2;
  const long iy2 = (long)y2 * xs + x;

  // The CPU declares sup0/sup1 double, but everything on the right of the
  // assignment is float: fabs of a float difference is float, so the sum is
  // rounded to float once and only then widened. Summing exactly here would
  // be more accurate and wrong.
  const float sup0 =
      fabs(xyb0[i] - xyb0[ix2]) + fabs(xyb0[i] - xyb0[iy2]);
  const float sup1 =
      fabs(xyb1[i] - xyb1[ix2]) + fabs(xyb1[i] - xyb1[iy2]);
  const float sup = min(sup0, sup1);
  float v = df_to_f(df_mul_f((df)(mul0_hi, mul0_lo), sup));
  // The CPU compares the already-rounded float against the double cutoff, and
  // assigns the double, so the stored value is the cutoff rounded to float.
  if (df_cmp_f((df)(cutoff_hi, cutoff_lo), v) <= 0) v = cutoff_hi;
  out[i] = v;
}

// Mask's Y component: normalizer * (muls0*blurred1 + muls1*blurred2).
__kernel void mask_y(__global const float* restrict b1,
                     __global const float* restrict b2,
                     __global float* restrict out, const float m0_hi,
                     const float m0_lo, const float m1_hi, const float m1_lo,
                     const float nz_hi, const float nz_lo, const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const df s = df_add(df_mul_f((df)(m0_hi, m0_lo), b1[i]),
                      df_mul_f((df)(m1_hi, m1_lo), b2[i]));
  out[i] = df_to_f(df_mul((df)(nz_hi, nz_lo), s));
}

// Mask's final pass. m0 and m1 arrive holding the blurred X and combined Y
// planes and are overwritten with the mask itself.
//
// c0 = mul[0]*w00 and c1 = mul[1]*w11 are folded host-side: they are products
// of two double constants, so folding them changes nothing and saves a
// double-float multiply per pixel.
__kernel void mask_final(__global float* restrict m0,
                         __global float* restrict m1,
                         __global float* restrict m2,
                         __global float* restrict dc0,
                         __global float* restrict dc1,
                         __global float* restrict dc2,
                         __global const float2* restrict lut_x,
                         __global const float2* restrict lut_y,
                         __global const float2* restrict lut_dcx,
                         __global const float2* restrict lut_dcy,
                         const float c0_hi, const float c0_lo,
                         const float c1_hi, const float c1_lo,
                         const float p1p0_hi, const float p1p0_lo,
                         const float hf_hi, const float hf_lo,
                         const float lf_hi, const float lf_lo, const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const df p1 = df_mul_f((df)(c1_hi, c1_lo), m1[i]);
  const df p0 = df_add(df_mul_f((df)(c0_hi, c0_lo), m0[i]),
                       df_mul((df)(p1p0_hi, p1p0_lo), p1));

  const df mask_y_p1 = mask_lut(lut_y, 512, p1);
  const df mask_dcy_p1 = mask_lut(lut_dcy, 512, p1);
  m0[i] = df_to_f(mask_lut(lut_x, 512, p0));
  m1[i] = df_to_f(mask_y_p1);
  m2[i] = df_to_f(df_mul((df)(hf_hi, hf_lo), mask_y_p1));
  dc0[i] = df_to_f(mask_lut(lut_dcx, 512, p0));
  dc1[i] = df_to_f(mask_dcy_p1);
  dc2[i] = df_to_f(df_mul((df)(lf_hi, lf_lo), mask_dcy_p1));
}

// ---------------------------------------------------------------------------
// CombineChannels and CalculateDiffmap. Float throughout except mul1.
// ---------------------------------------------------------------------------

__kernel void combine_channels(__global const float* restrict m0,
                               __global const float* restrict m1,
                               __global const float* restrict m2,
                               __global const float* restrict d0,
                               __global const float* restrict d1,
                               __global const float* restrict d2,
                               __global const float* restrict ac0,
                               __global const float* restrict ac1,
                               __global const float* restrict ac2,
                               __global const float* restrict dc0,
                               __global const float* restrict dc1,
                               __global const float* restrict dc2,
                               __global float* restrict out, const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const float dot_dc = dc0[i] * d0[i] + dc1[i] * d1[i] + dc2[i] * d2[i];
  const float dot_ac = m0[i] * ac0[i] + m1[i] * ac1[i] + m2[i] * ac2[i];
  out[i] = dot_dc + dot_ac;
}

// Take the square root, avoiding sqrt on very small numbers as the CPU does.
__kernel void diffmap_sqrt(__global const float* restrict in,
                           __global float* restrict out, const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const float v = in[i];
  const float kInitialSlope = 100.0f;
  out[i] = v < (1.0f / (kInitialSlope * kInitialSlope)) ? kInitialSlope * v
                                                        : sqrt(v);
}

// diffmap = (diffmap + mul1 * blurred) * scale.
__kernel void diffmap_final(__global float* restrict diffmap,
                            __global const float* restrict blurred,
                            const float mul1_hi, const float mul1_lo,
                            const float scale, const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const df t = df_mul_f((df)(mul1_hi, mul1_lo), blurred[i]);
  diffmap[i] = df_to_f(df_add_f(t, diffmap[i])) * scale;
}

// Head of SameNoiseLevels: out = clamp(|i0|) - clamp(|i1|), where the clamp
// bound is a double the float inputs are compared and assigned against.
__kernel void noise_clamp(__global const float* restrict i0,
                          __global const float* restrict i1,
                          __global float* restrict out, const float mc_hi,
                          const float mc_lo, const int n) {
  const int i = get_global_id(0);
  if (i >= n) return;
  const df mc = (df)(mc_hi, mc_lo);
  const float a = fabs(i0[i]), b = fabs(i1[i]);
  const df v0 = df_cmp_f(mc, a) < 0 ? mc : (df)(a, 0.0f);
  const df v1 = df_cmp_f(mc, b) < 0 ? mc : (df)(b, 0.0f);
  out[i] = df_to_f(df_add(v0, df_neg(v1)));
}
