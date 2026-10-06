#!/bin/sh
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
src_dir="$script_dir/src"
build_dir="${PROJECT_TEMP_DIR:-/tmp}/jpegli-build"

if [ ! -d "$src_dir" ]; then
    echo "Cloning google/jpegli..."
    git clone --depth 1 https://github.com/google/jpegli.git "$src_dir"
    (cd "$src_dir" && ./deps.sh)
fi

if command -v cmake >/dev/null 2>&1; then
    cmake=$(command -v cmake)
elif [ -x /opt/homebrew/bin/cmake ]; then
    cmake=/opt/homebrew/bin/cmake
elif [ -x /usr/local/bin/cmake ]; then
    cmake=/usr/local/bin/cmake
else
    echo "CMake is required to build cjpegli" >&2
    exit 1
fi

cmake_args="-DBUILD_SHARED_LIBS=OFF -DJPEGLI_ENABLE_TOOLS=ON -DJPEGLI_ENABLE_TESTS=OFF -DBUILD_TESTING=OFF -DJPEGLI_ENABLE_DOXYGEN=OFF -DJPEGLI_ENABLE_OPENEXR=OFF -DCMAKE_DISABLE_FIND_PACKAGE_GIF=TRUE -DJPEGLI_BUNDLE_LIBPNG=ON"

if [ -f "/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.a" ]; then
    cmake_args="$cmake_args -DJPEG_LIBRARY=/opt/homebrew/opt/jpeg-turbo/lib/libjpeg.a"
fi

"$cmake" -S "$src_dir" -B "$build_dir" $cmake_args
"$cmake" --build "$build_dir" --target cjpegli -j 8

install -m 755 "$build_dir/tools/cjpegli" "$script_dir/cjpegli"
echo "Built $script_dir/cjpegli successfully"
