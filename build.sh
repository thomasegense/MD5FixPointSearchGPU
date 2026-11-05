#!/bin/sh
# Build the CUDA library and run the Java host on Linux.
# Needs: CUDA Toolkit (nvcc), g++, JDK 22 or newer.
#
# Optional settings:
#   JAVA=/path/to/jdk/bin/java   Java 22+ to use (default: java)
#   LOAD=100                     GPU load in percent (default: 50)
#   CCBIN=g++-12                 host compiler for nvcc (default: automatic)
set -e
cd "$(dirname "$0")"

JAVA="${JAVA:-java}"
if ! "$JAVA" -version 2>&1 | grep -Eq 'version "(2[2-9]|[3-9][0-9])'; then
  echo "Java 22 or newer is needed. Run e.g.: JAVA=/usr/lib/jvm/java-25-openjdk-amd64/bin/java ./build.sh"
  exit 1
fi

# Find nvcc, also when CUDA is installed but not on the PATH
if command -v nvcc >/dev/null 2>&1; then
  NVCC=nvcc
elif [ -x /usr/local/cuda/bin/nvcc ]; then
  NVCC=/usr/local/cuda/bin/nvcc
else
  echo "nvcc not found. Install the CUDA Toolkit or add its bin folder to PATH."
  exit 1
fi

# Optional CPU check of the MD5 step code (no GPU needed)
g++ -O2 -x c++ -DMD5_CPU_TEST md5search.cu -o md5test
./md5test | tail -1

# GPU library for the installed GPU (-arch=native, e.g. sm_86 for RTX 30xx, sm_89 for RTX 40xx).
# -Xptxas -v prints register use.
FLAGS="-O3 -arch=native -Xptxas -v -Xcompiler -fPIC -shared -o libmd5search.so md5search.cu"
if [ -n "$CCBIN" ]; then
  $NVCC -ccbin "$CCBIN" $FLAGS
elif ! $NVCC $FLAGS; then
  # Older CUDA versions reject new GCC versions: retry with an older g++ if installed
  for cc in g++-13 g++-12 g++-11; do
    if command -v $cc >/dev/null 2>&1; then
      echo "Retrying with host compiler $cc"
      if $NVCC -ccbin $cc $FLAGS; then ok=1; break; fi
    fi
  done
  if [ -z "$ok" ]; then
    echo "nvcc failed. If it says 'unsupported GNU version', install an older g++,"
    echo "e.g. 'sudo apt install g++-12', and run ./build.sh again."
    exit 1
  fi
fi

exec "$JAVA" -Dmd5.load="${LOAD:-50}" --enable-native-access=ALL-UNNAMED Md5Search.java
