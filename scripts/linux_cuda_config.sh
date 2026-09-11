#!/usr/bin/env bash
## @file
## @brief Select the Linux CUDA build without silently disabling NVIDIA capture.
# shellcheck disable=SC2034 # CUDA_FLAG and CUDA_FLAGS are consumed by the caller.

## @brief Probe CUDA compilation and select a compatible installed host compiler.
## @param $1 Path to the CUDA compiler.
## @return Zero when compilation succeeds, nonzero with recovery instructions otherwise.
## @details Honors CUDAHOSTCXX without fallback. Otherwise tries gcc followed by
## installed versioned GCC executables, newest first. Updates CUDA_FLAGS only
## after a successful probe, including flags that replace stale CMake cache values.
prism_configure_cuda_host() {
  local compiler="$1" probe_dir host candidate selected=""
  local -a candidates=() probe_flags=()
  if [ "${PRISM_CUDA_ALLOW_UNSUPPORTED_COMPILER:-0}" = 1 ]; then
    probe_flags+=(-allow-unsupported-compiler)
  fi
  if [ -n "${CUDAHOSTCXX:-}" ]; then
    host="$(command -v "$CUDAHOSTCXX")" || {
      echo "ERROR: CUDAHOSTCXX does not name an executable host compiler: $CUDAHOSTCXX" >&2
      return 1
    }
    candidates+=("$host")
  else
    if host="$(command -v gcc)"; then
      candidates+=("$host")
    fi
    while IFS= read -r candidate; do
      [[ "$candidate" =~ ^gcc-[0-9]+$ ]] || continue
      candidates+=("$(command -v "$candidate")")
    done < <(compgen -c | sort -Vr -u)
  fi
  probe_dir="$(mktemp -d)" || return 1
  printf '%s\n' '#include <cuda_runtime.h>' 'int main() { return 0; }' > "$probe_dir/probe.cu"
  for host in "${candidates[@]}"; do
    if "$compiler" "${probe_flags[@]}" -ccbin "$host" -c "$probe_dir/probe.cu" \
      -o "$probe_dir/probe.o" > "$probe_dir/probe.log" 2>&1; then
      selected="$host"
      break
    fi
  done
  if [ -z "$selected" ]; then
    [ ! -f "$probe_dir/probe.log" ] || cat "$probe_dir/probe.log" >&2
    rm -rf "$probe_dir"
    echo 'ERROR: CUDA could not compile with the available host compilers.' >&2
    echo 'Install a GCC version supported by your CUDA toolkit and set CUDAHOSTCXX to its executable, then rerun the installer.' >&2
    echo 'Use PRISM_ENABLE_CUDA=OFF only when intentionally building without NVIDIA headless HDR.' >&2
    return 1
  fi
  rm -rf "$probe_dir"
  CUDA_FLAGS+=("-DCMAKE_CUDA_HOST_COMPILER=$selected" "-DCMAKE_CUDA_FLAGS=${probe_flags[*]}")
  echo "CUDA host compiler verified: $selected"
}

## @brief Populate CUDA_FLAG and CUDA_FLAGS for the source installer.
## @param $1 Optional DRM sysfs root, for isolated dependency checks.
## @return Zero on a usable configuration, nonzero on missing or unusable requested CUDA.
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
    CUDA_FLAGS=("-DCMAKE_CUDA_COMPILER=$compiler")
    prism_configure_cuda_host "$compiler" || return 1
    CUDA_FLAG=ON
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
