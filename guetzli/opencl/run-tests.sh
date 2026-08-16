#!/bin/bash
# Builds and runs clba_test: every ported stage, CPU against GPU, on the same
# inputs. It reports per-stage what fraction of pixels matched exactly, so a
# regression shows up as a stage name rather than as a slightly different JPEG.
#
# -ffp-contract=off is what makes "exactly" achievable: without it clang fuses
# a*b+c into an FMA in the CPU code, which no OpenCL kernel can reproduce. The
# Xcode target carries the same flag, for the same reason.
#
# Run from anywhere; builds into build/ next to this script.
set -e
cd "$(dirname "$0")/.."
make
cd opencl
mkdir -p build
FLAGS="-O2 -ffp-contract=off -std=c++11 -I .. -I ../guetzli -I ../guetzli/third_party/butteraugli -Wno-unused-variable"
clang++ $FLAGS -c ../guetzli/third_party/butteraugli/butteraugli/butteraugli.cc -o build/butteraugli.o
clang++ $FLAGS -c clba.cc      -o build/clba.o
clang++ $FLAGS -c clba_test.cc -o build/clba_test.o
clang++ -o build/clba_test build/butteraugli.o build/clba.o build/clba_test.o -framework OpenCL
exec build/clba_test "$@"
