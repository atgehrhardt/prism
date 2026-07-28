#!/usr/bin/env bash
# Shared, idempotent PulseAudio/PipeWire lifecycle helpers for Prism sessions.
#
# This file is sourced by capture-mode scripts. It deliberately parses state
# files as data instead of sourcing them as shell code.

prism_audio_state_get() {
  local file="${1:?state file required}"
  local key="${2:?state key required}"

  case "$key" in
    *[!A-Za-z0-9_]*) return 1 ;;
  esac
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  awk -v wanted="$key" '
    {
      separator = index($0, "=")
      if (separator < 2) {
        invalid = 1
        next
      }
      key = substr($0, 1, separator - 1)
      if (key !~ /^[A-Za-z0-9_]+$/ || ++seen[key] != 1) {
        invalid = 1
        next
      }
      if (key == wanted) {
        value = substr($0, separator + 1)
        found = 1
      }
    }
    END {
      if (invalid || !found) exit 1
      print value
    }
  ' "$file"
}

prism_audio_atomic_write() {
  local target="${1:?state path required}"
  local temporary="${target}.tmp.$$"

  umask 077
  if ! cat > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  mv -f "$temporary" "$target"
}

prism_audio_module_exists() {
  local module="${1:?module id required}"
  local modules

  modules="$(pactl list short modules 2>/dev/null)" || return 2
  printf '%s\n' "$modules" |
    awk -v wanted="$module" '$1 == wanted {found=1} END {exit !found}'
}

prism_unload_module() {
  local module="${1:-}"
  local exists_status

  case "$module" in
    '' | *[!0-9]*) return 0 ;;
  esac
  prism_audio_module_exists "$module" || {
    exists_status=$?
    if [ "$exists_status" -eq 1 ]; then
      return 0
    fi
    echo "ERROR: could not inspect audio module $module" >&2
    return 1
  }
  pactl unload-module "$module" >/dev/null 2>&1 || return 1
  if prism_audio_module_exists "$module"; then
    echo "ERROR: audio module $module remains loaded" >&2
    return 1
  else
    exists_status=$?
    [ "$exists_status" -eq 1 ] || return 1
  fi
}

prism_unload_named_sink_modules() {
  local sink="${1:?sink required}" listing
  local module failed=0
  local -a modules=()

  if ! listing="$(pactl list short modules 2>/dev/null)"; then
    echo "ERROR: could not inspect null-sink modules for $sink" >&2
    return 1
  fi
  mapfile -t modules < <(
    printf '%s\n' "$listing" |
      awk -v token="sink_name=$sink" '
        $2 == "module-null-sink" {
          for (i = 3; i <= NF; ++i) {
            if ($i == token) {
              print $1
              break
            }
          }
        }
      '
  )
  for module in "${modules[@]}"; do
    prism_unload_module "$module" || failed=1
  done
  return "$failed"
}

prism_unload_loopback_modules() {
  local source="${1:-}" listing
  local sink="${2:?destination sink required}"
  local module failed=0
  local -a modules=()

  if ! listing="$(pactl list short modules 2>/dev/null)"; then
    echo "ERROR: could not inspect loopbacks routed to $sink" >&2
    return 1
  fi
  mapfile -t modules < <(
    printf '%s\n' "$listing" |
      awk -v source_token="source=$source" -v sink_token="sink=$sink" '
        $2 == "module-loopback" {
          source_found = (source_token == "source=")
          sink_found = 0
          for (i = 3; i <= NF; ++i) {
            if ($i == source_token) source_found = 1
            if ($i == sink_token) sink_found = 1
          }
          if (source_found && sink_found) print $1
        }
      '
  )
  for module in "${modules[@]}"; do
    prism_unload_module "$module" || failed=1
  done
  return "$failed"
}

prism_unload_prism_capture_loopbacks() {
  prism_unload_loopback_modules "" prism-stream
}

prism_audio_remove_owned_state() {
  local state="${1:?state path required}"
  local loop_module="${2:-}"
  local current

  current="$(prism_audio_state_get "$state" loop_module 2>/dev/null || true)"
  if [ -n "$loop_module" ] && [ "$current" = "$loop_module" ]; then
    rm -f "$state"
  fi
}
