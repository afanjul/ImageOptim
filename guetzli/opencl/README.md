# OpenCL butteraugli

guetzli spends almost all of its time asking butteraugli "how different do these
two images look?", about a hundred times per image. This directory is that
question, answered on the GPU.

The submodule stays pinned to pristine google/guetzli `214f2bb`. Three hooks
inside butteraugli are carried as `butteraugli-opencl.patch`, applied by
`../Makefile` at build time; everything else lives here.

Measured on an M1 Max: **2.6x–2.9x** end-to-end on real images, with the diffmap
itself 6.6x and the isolated `DiffmapPsychoImage` 48x. Output is byte-identical
to the CPU build.

## Why the fork was not used instead

There is a well-known GPU fork of guetzli (Tencent's, maintained as
`doterax/guetzli-cuda-opencl`). It was integrated and measured first, and
rejected: at the same `--quality 90` it produces files **8.8% to 30.9% larger**
than stock guetzli. It ports the 2016 butteraugli, and guetzli's search is a
threshold search against the metric, so a metric that is merely close is a
different encoder. Accelerating stock guetzli means the reference is correct by
construction.

## Bit-exactness, and the flag that buys it

Every stage here was checked against the CPU function it replaces by **exact
equality**, not by tolerance. Two things make that possible:

**`-ffp-contract=off` (and `-fno-fast-math`), per-file, on `butteraugli.cc` and
`clba.cc`.** Left alone, clang fuses `a*b+c` into an FMA, and no OpenCL kernel
can reproduce that rounding. The rest of the target keeps the project's
`GCC_FAST_MATH`; only these two files compute things that also exist as kernels,
so only these two have to agree. Cost is about 3% of total runtime.

**Double-float arithmetic.** Apple GPUs have no `cl_khr_fp64`, and butteraugli
uses `double` for some intermediates. Those are emulated with a `float2`
carrying ~48 bits of mantissa (`df_*` in `kernels.cl`).

The subtle half of the work was matching butteraugli's **rounding sites** rather
than its accuracy. In

```c++
double sup0 = fabs(f1 - f2) + fabs(f1 - f3);
```

everything on the right is `float`, so the sum is rounded to `float` once and
only then widened. Emulating that sum exactly is more accurate — and wrong. That
one line was the difference between 94% and 100% agreement.

## Known residual

At 1024x781, `DiffPrecompute` on one plane and `mask_dc[0]` each differ in
**exactly one pixel out of 799,744**, by one ulp. That is the double-rounding
tail of 48-bit double-float against 53-bit `double`; closing it would need
triple-float expansions throughout. It does not reach the output: guetzli's
JPEGs are byte-identical either way on every image tested.

## Layout

| | |
|---|---|
| `clba.h` / `clba.cc` | host side: device setup, plane pool, one function per butteraugli stage |
| `kernels.cl` | the kernels, plus the `df` double-float library |
| `gen_kernels.py` | expands `@MALTA_UNITS@` in `kernels.cl` with the two `MaltaUnit` bodies lifted verbatim from `butteraugli.cc`, then embeds the result in `clba_kernels.h` |
| `clba_test.cc` | CPU vs GPU, stage by stage, plus throughput benchmarks |
| `butteraugli-opencl.patch` | the three hooks inside the submodule |
| `run-tests.sh` | builds and runs the above |

`clba_kernels.h` and `kernels_gen.cl` are generated, not committed — part of the
kernel source is lifted out of `butteraugli.cc`, and generating it at build time
is what keeps the two from drifting apart.

## Design notes

* A `clFinish` round-trip costs ~221 us on this hardware; enqueuing a kernel
  costs ~3.5 us. So an entire diffmap — around 30 kernel launches — is enqueued
  as one chain and synchronised exactly once, at the download. `pi0`, the
  decomposition of the original image, is uploaded once and stays resident for
  all ~100 comparisons.
* Device planes are packed; `ImageF` pads its rows. Conversion happens only at
  the host boundary.
* If no usable OpenCL device is found, `clba::Available()` returns false and
  every path stays on the CPU. Setting `CLBA_DISABLE=1` forces that, which is
  how the two are compared; `CLBA_VERBOSE=1` prints the device and any build
  log.

## Running the tests

```sh
./run-tests.sh
```

Each stage prints the fraction of pixels that matched exactly. Anything below
100% with a nonzero differ count is a regression, with the one exception noted
above.
