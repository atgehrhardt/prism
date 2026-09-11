#!/usr/bin/env bash
## @file
## @brief Select the Linux CUDA build without silently disabling NVIDIA capture.
# shellcheck disable=SC2034 # CUDA_FLAG and CUDA_FLAGS are consumed by the caller.

## @brief Populate CUDA_FLAG and CUDA_FLAGS for the source installer.
## @param $1 Optional DRM sysfs root, for isolated dependency checks.
## @return Zero on a usable configuration, nonzero on missing requested CUDA.
prism_configure_cuda() {
  local drm_root="${1:-/sys/class/drm}" vendor_file vendor mode compiler=""
  mode="${PRISM_ENABLE_CUDA:-AUTO}"
  mode="${mode^^}"
  CUDA_FLAG=OFF
  CUDA_FLAGS=()
  case "$mode" in
    AUTO | ON | OFF) ;;
    *) echo 'ERROR: PRISM_ENABLE_CUDA must be AUTO, ON, or OFF' >&2; return 1 ;;
  esac
  if [ "$mode" = OFF ]; then
    echo 'CUDA disabled explicitly; NVIDIA headless HDR will be unavailable.'
    return 0
  fi

  if [ -n "${CUDACXX:-}" ]; then
    compiler="$(command -v "$CUDACXX")" || {
      echo "ERROR: CUDACXX does not name an executable CUDA compiler: $CUDACXX" >&2
      return 1
    }
  elif command -v nvcc >/dev/null 2>&1; then
    compiler="$(command -v nvcc)"
  elif [ -x "${CUDA_PATH:-/usr/local/cuda}/bin/nvcc" ]; then
    compiler="${CUDA_PATH:-/usr/local/cuda}/bin/nvcc"
  fi

  if [ -n "$compiler" ]; then
    CUDA_FLAG=ON
    CUDA_FLAGS=("-DCMAKE_CUDA_COMPILER=$compiler")
    if [ "${PRISM_CUDA_ALLOW_UNSUPPORTED_COMPILER:-0}" = 1 ]; then
      CUDA_FLAGS+=("-DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler")
    fi
    echo "CUDA capture enabled using $compiler"
    return 0
  fi

  # Check the device vendor rather than nvidia-smi: driver utilities need not
  # be on a user service's PATH and PRIME hosts may expose several GPUs.
  for vendor_file in "$drm_root"/renderD*/device/vendor "$drm_root"/card*/device/vendor; do
    [ -r "$vendor_file" ] || continue
    read -r vendor < "$vendor_file"
    if [ "${vendor,,}" = 0x10de ]; then
      mode=ON
      break
    fi
  done
  if [ "$mode" = ON ]; then
    echo 'ERROR: NVIDIA capture needs a CUDA toolkit (nvcc >= 12). Install it and set CUDACXX if it is outside PATH.' >&2
    echo 'Use PRISM_ENABLE_CUDA=OFF only when intentionally building without NVIDIA headless HDR.' >&2
    return 1
  fi
  echo 'No NVIDIA GPU or CUDA toolkit detected; building the VAAPI paths without CUDA.'
}
