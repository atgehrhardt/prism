#!/usr/bin/env bash
## @file
## @brief Download, verify, and install a Prism release without a source checkout.
set -euo pipefail

## @brief Install a verified AppImage, restoring the previous image on failure.
main() (
  [ "$(uname -s)" = Linux ] || { echo 'Prism requires Linux.' >&2; exit 1; }
  [ "$(id -u)" != 0 ] || { echo 'Run as your desktop user, without sudo.' >&2; exit 1; }
  case "$(uname -m)" in
    x86_64) architecture=x86_64 ;;
    *) echo 'AppImage releases currently support x86_64 only.' >&2; exit 1 ;;
  esac
  for command in curl python3 sha256sum systemctl flock; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
  done
  systemctl --user show-environment >/dev/null
  data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  case "$data_home" in /*) ;; *) data_home="$HOME/.local/share" ;; esac
  destination="$data_home/prism"
  mkdir -p "$destination"
  exec 9>"$destination/.install.lock"
  flock -n 9 || { echo 'Another Prism installation is running.' >&2; exit 1; }
  temporary="$(mktemp -d "$destination/.install.XXXXXXXX")"
  image="$destination/prism.AppImage"
  replaced=0
  committed=0
  was_active=0
  integration_saved=0
  systemctl --user is-active --quiet prism.service && was_active=1

  ## @brief Save or restore only the user files touched by AppImage integration.
  ## @param $1 Either save or restore.
  integration() {
    python3 - "$1" "$temporary/integration.json" <<'PY'
import base64, json, os, pathlib, sys
home = pathlib.Path.home()
config = pathlib.Path(os.environ.get('XDG_CONFIG_HOME') or home / '.config')
if not config.is_absolute():
    config = home / '.config'
units = config / 'systemd/user'
names = ('prism', 'prism-headless-session', 'prism-input-bridge', 'prism-headless-steam', 'prism-steam-restore')
paths = [units / (name + '.service') for name in names]
paths += [units / 'graphical-session.target.wants/prism.service', home / '.local/bin/prism',
          config / 'prism/apps.json', config / 'prism/prism.conf']
snapshot = pathlib.Path(sys.argv[2])
if sys.argv[1] == 'save':
    data = {}
    for path in paths:
        if path.is_symlink():
            value = {'link': os.readlink(path)}
        elif path.exists():
            value = {'data': base64.b64encode(path.read_bytes()).decode(), 'mode': path.stat().st_mode & 0o777}
        else:
            value = None
        data[str(path)] = value
    snapshot.write_text(json.dumps(data))
else:
    for name, value in json.loads(snapshot.read_text()).items():
        path = pathlib.Path(name)
        path.unlink(missing_ok=True)
        if value is not None:
            path.parent.mkdir(parents=True, exist_ok=True)
            if 'link' in value:
                path.symlink_to(value['link'])
            else:
                path.write_bytes(base64.b64decode(value['data']))
                path.chmod(value['mode'])
PY
  }

  ## @brief Restore the previous release after failure and remove temporary files.
  # shellcheck disable=SC2317 # Invoked indirectly by the EXIT trap.
  cleanup() {
    status=$?
    if [ "$integration_saved" = 1 ] && [ "$committed" = 0 ]; then
      systemctl --user stop prism.service >/dev/null 2>&1 || true
      integration restore
      systemctl --user daemon-reload || true
    fi
    if [ "$replaced" = 1 ] && [ "$committed" = 0 ]; then
      if [ -f "$temporary/previous.AppImage" ]; then
        mv -f "$temporary/previous.AppImage" "$image"
      else
        rm -f "$image"
      fi
      echo 'Installation failed; the previous AppImage was restored if present.' >&2
    fi
    if [ "$integration_saved" = 1 ] && [ "$committed" = 0 ] && [ "$was_active" = 1 ]; then
      systemctl --user restart prism.service || true
    fi
    rm -rf "$temporary"
    exit "$status"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  version="${PRISM_VERSION:-latest}"
  case "$version" in ''|*[!a-zA-Z0-9._-]*) echo 'Invalid PRISM_VERSION.' >&2; exit 1 ;; esac
  base=https://github.com/atgehrhardt/prism/releases
  if [ "$version" = latest ]; then
    base="$base/latest/download"
  else
    base="$base/download/$version"
  fi
  asset="prism-$architecture.AppImage"
  if [ -n "${PRISM_APPIMAGE:-}" ]; then
    echo "Verifying local AppImage: $PRISM_APPIMAGE"
    cp "$PRISM_APPIMAGE" "$temporary/$asset"
    cp "$PRISM_APPIMAGE.sha256" "$temporary/checksum"
  else
    echo "Downloading Prism $version ($architecture)"
    curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 \
      "$base/$asset" --output "$temporary/$asset"
    curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 \
      "$base/$asset.sha256" --output "$temporary/checksum"
  fi
  # Read only the digest; never let a downloaded checksum name arbitrary files.
  read -r digest _ < "$temporary/checksum"
  [[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || { echo 'Invalid SHA-256 checksum.' >&2; exit 1; }
  (cd "$temporary" && printf '%s  %s\n' "$digest" "$asset" | sha256sum --check --status)
  chmod 755 "$temporary/$asset"
  "$temporary/$asset" --check
  integration save
  integration_saved=1
  # Stop existing services before replacing their unit definitions or mounted image.
  for unit in prism-steam-restore prism-headless-steam prism-input-bridge prism-headless-session prism; do
    if systemctl --user cat "$unit.service" >/dev/null 2>&1; then
      systemctl --user stop "$unit.service"
    fi
  done
  # All new units use the stable path, never the temporary download or mount.
  "$temporary/$asset" --install "$image"
  if [ -f "$image" ]; then
    cp -p "$image" "$temporary/previous.AppImage"
  fi
  replaced=1
  mv -f "$temporary/$asset" "$image"
  systemctl --user enable prism.service
  systemctl --user restart prism.service
  # Detect immediate startup failures, including missing host libraries.
  sleep 2
  systemctl --user is-active --quiet prism.service
  committed=1
  echo "Prism installed: $image"
  echo 'Open https://localhost:47990 to configure Prism and pair Moonlight.'
)

# Parse the full script before subprocesses run; curl | bash must not share stdin.
main "$@" </dev/null
