#!/usr/bin/env bash
# One entry point for the whole project.
#
#   ./run.sh           check the toolchain, prove the laws, build, open the viewer
#   ./run.sh proof     just run the proof gate
#   ./run.sh build     just build the binaries
#   ./run.sh bench     build, then time the renderer on 1 core, all cores and the GPU
#   ./run.sh doctor    report what the toolchain looks like and stop

set -euo pipefail
cd "$(dirname "$0")"

# Bend looks for CUDA at $CUDA_HOME, else /usr/local/cuda. Distro packages
# often put it elsewhere (Arch uses /opt/cuda), so find it before building.
find_cuda() {
  if [ -n "${CUDA_HOME:-}" ] && [ -f "$CUDA_HOME/include/nvrtc.h" ]; then
    echo "$CUDA_HOME"; return
  fi
  for d in /usr/local/cuda /opt/cuda /usr/lib/cuda; do
    [ -f "$d/include/nvrtc.h" ] && { echo "$d"; return; }
  done
  if command -v nvcc >/dev/null 2>&1; then
    d=$(dirname "$(dirname "$(readlink -f "$(command -v nvcc)")")")
    [ -f "$d/include/nvrtc.h" ] && { echo "$d"; return; }
  fi
  echo ""
}

doctor() {
  echo "== toolchain =="
  command -v bend  >/dev/null && echo "bend    $(bend --version 2>/dev/null | tail -1)" \
                              || echo "bend    MISSING -- curl -fsSL https://bend-lang.com/install.sh | sh"
  if command -v clang >/dev/null; then
    # Careful with pipefail below: a `head` that exits early SIGPIPEs its
    # producer, which would fail the whole pipeline.
    ver=$(clang --version 2>/dev/null || true)
    v=$(printf '%s' "$ver" | sed -n '1s/.*version \([0-9]*\).*/\1/p')
    if [ -n "$v" ] && [ "$v" -ge 19 ]; then
      echo "clang   $v (ok, 19+ required for '!')"
    else
      echo "clang   ${v:-unknown} -- 19+ required for GPU calls"
    fi
  else
    echo "clang   MISSING -- required"
  fi
  if [ -n "$CUDA" ]; then
    echo "cuda    $CUDA"
  else
    echo "cuda    not found -- the binary still builds and runs on the CPU"
  fi
  if command -v nvidia-smi >/dev/null; then
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
      | sed 's/^/gpu     /' || true
  else
    echo "gpu     no nvidia-smi"
  fi
  if [ -n "$(ls /usr/lib*/libX11.so* /usr/lib/*/libX11.so* 2>/dev/null || true)" ]; then
    echo "libX11  ok"
  else
    echo "libX11  MISSING -- the window needs libx11-dev"
  fi
}

CUDA="$(find_cuda)"
[ -n "$CUDA" ] && export CUDA_HOME="$CUDA"

proof() {
  echo "== proving LAWS.bend =="
  bend PROOF.bend
}

build() {
  echo "== building =="
  bend main.bend  -o rtracer
  bend bench.bend -o bench
  echo "built ./rtracer and ./bench"
}

bench() {
  echo "(headless trace only, with a forcing pass -- not frame times)"
  echo "== 1) CPU, single thread =="
  ./bench --gpu off --threads 1
  echo
  echo "== 2) CPU, all $(nproc) threads =="
  ./bench --gpu off
  echo
  echo "== 3) GPU (the default when the binary has '!' calls) =="
  ./bench
}

case "${1:-all}" in
  doctor) doctor ;;
  proof)  proof ;;
  build)  build ;;
  bench)  build; bench ;;
  all)    doctor; echo; proof; echo; build; echo
          echo "== viewer: left-drag orbits, right-drag zooms, Up/Down also zoom, Esc quits =="
          echo "   (the mouse wheel cannot be used -- Bend 2.0.5 discards wheel"
          echo "    events before a program sees them; see NOTES-BEND.md)"
          ./rtracer ;;
  *)      echo "usage: $0 [all|doctor|proof|build|bench]" >&2; exit 2 ;;
esac
