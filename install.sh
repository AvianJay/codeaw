#!/bin/sh
# Install the standalone Linux/macOS bridge and its bundled web app.
set -eu

fail() {
    printf 'codeaw: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: sh install.sh [options]

  --version TAG       Release tag to install (default: nightly; latest = stable)
  --install-dir DIR   Application directory (default: ~/.local/share/codeaw-bridge)
  --bin-dir DIR       Command directory (default: ~/.local/bin)
  -h, --help          Show this help

Directories must be absolute paths. Run as your normal user; sudo is not needed.
Tailscale and ACP agents are installed separately. Rerun to update, then restart
the bridge process (or its user service) to load the new executable.
EOF
}

download() {
    curl --fail --location --silent --show-error --retry 3 \
        --connect-timeout 15 --max-time 300 --proto '=https' --proto-redir '=https' \
        --output "$2" "$1" || fail "Download failed: $1 (check the release tag and try again)."
}

quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

# Keep the installation inside a function so a truncated curl | sh download
# cannot execute a partially received installation sequence.
main() {
    version=nightly
    install_dir=${XDG_DATA_HOME:-"$HOME/.local/share"}/codeaw-bridge
    bin_dir=$HOME/.local/bin
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version|--install-dir|--bin-dir)
                [ "$#" -ge 2 ] && [ -n "$2" ] || fail "Missing value for $1"
                case "$1" in
                    --version) version=$2 ;;
                    --install-dir) install_dir=$2 ;;
                    --bin-dir) bin_dir=$2 ;;
                esac
                shift 2 ;;
            -h|--help) usage; return ;;
            *) fail "Unknown option: $1 (see --help)" ;;
        esac
    done

    case "$version" in
        ''|.|..|-*|*[!a-zA-Z0-9._-]*) fail "Invalid release tag: $version" ;;
    esac
    system=$(uname -s)
    case "$system" in Linux|Darwin) ;; *) fail "This installer supports Linux and macOS only." ;; esac
    case "$(uname -m)" in
        x86_64|amd64) arch=x64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) fail "Unsupported CPU architecture; x64 and ARM64 are available." ;;
    esac
    for command in curl tar awk sed mktemp mkdir mv rm ln readlink chmod; do
        command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"
    done
    if [ "$system" = Darwin ]; then
        target=macos-$arch
        command -v shasum >/dev/null 2>&1 || fail "Required command not found: shasum"
    else
    command -v sha256sum >/dev/null 2>&1 || fail "Required command not found: sha256sum"
    libc=$(ldd --version 2>&1 || true)
    case "$libc" in
        *musl*) target=linux-$arch-musl ;;
        *GLIBC*|*glibc*|*GNU*) target=linux-$arch ;;
        *)
            if getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
                target=linux-$arch
            else
                target=
                for loader in /lib/ld-musl-*.so.1; do
                    if [ -f "$loader" ]; then target=linux-$arch-musl; break; fi
                done
                [ -n "$target" ] || fail "Cannot detect glibc or musl on this system."
            fi ;;
    esac
    fi

    case "$install_dir" in /*) ;; *) fail "--install-dir must be an absolute path." ;; esac
    case "$bin_dir" in /*) ;; *) fail "--bin-dir must be an absolute path." ;; esac
    # Never replace an arbitrary directory or follow an application symlink.
    install_dir=${install_dir%/}
    install_name=${install_dir##*/}
    case "$install_name" in ''|.|..) fail "Choose a dedicated application directory." ;; esac
    [ ! -L "$install_dir" ] || fail "Installation directory is a symlink: $install_dir"
    install_parent=${install_dir%/*}
    mkdir -p "${install_parent:-/}" "$bin_dir"
    install_parent=$(CDPATH='' cd -- "${install_parent:-/}" && pwd -P)
    bin_dir=$(CDPATH='' cd -- "$bin_dir" && pwd -P)
    install_dir=${install_parent%/}/$install_name
    case "$bin_dir/" in "$install_dir/"*) fail "--bin-dir must be outside --install-dir." ;; esac
    if [ -e "$install_dir" ]; then
        [ -f "$install_dir/.codeaw-installer" ] || fail "Directory already exists and was not created by this installer: $install_dir"
    fi
    link=$bin_dir/codeaw-bridge
    if [ -e "$link" ] || [ -L "$link" ]; then
        [ -L "$link" ] && [ "$(readlink "$link")" = "$install_dir/codeaw-bridge" ] \
            || fail "Refusing to replace an existing command: $link"
    fi

    stage=$(mktemp -d "$install_parent/.codeaw-install.XXXXXX")
    promoted=false
    committed=false
    cleanup() {
        result=$?
        trap - 0 HUP INT TERM
        if [ "$committed" = false ]; then
            if [ "$promoted" = true ]; then rm -rf -- "$install_dir"; fi
            if [ -d "$stage/previous" ]; then
                if ! mv -- "$stage/previous" "$install_dir"; then
                    printf 'codeaw: Could not restore the previous install; recover it from %s/previous\n' "$stage" >&2
                    exit 1
                fi
            fi
        fi
        rm -rf -- "$stage"
        exit "$result"
    }
    trap cleanup 0
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM

    asset=codeaw-bridge-$target.tar.gz
    base=https://github.com/AvianJay/codeaw/releases
    if [ "$version" = latest ]; then base=$base/latest/download
    else base=$base/download/$version; fi
    printf 'Installing codeaw bridge (%s, %s)...\n' "$version" "$target"
    download "$base/SHA256SUMS" "$stage/SHA256SUMS"
    checksum=$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$stage/SHA256SUMS")
    [ "${#checksum}" -eq 64 ] || fail "Missing or duplicate SHA-256 checksum for $asset"
    case "$checksum" in *[!a-fA-F0-9]*) fail "Invalid SHA-256 checksum for $asset" ;; esac
    download "$base/$asset" "$stage/$asset"
    printf '%s  %s\n' "$checksum" "$asset" | (cd "$stage" && if [ "$system" = Darwin ]; then shasum -a 256 -c -; else sha256sum -c -; fi) \
        || fail "Checksum verification failed; nothing was installed. Retry if nightly was being published."

    mkdir "$stage/payload"
    tar -xzf "$stage/$asset" -C "$stage/payload" --no-same-owner
    [ -f "$stage/payload/codeaw-bridge" ] && [ ! -L "$stage/payload/codeaw-bridge" ] \
        || fail "Archive is missing the bridge executable."
    [ -f "$stage/payload/web/index.html" ] || fail "Archive is missing the bundled web app."
    chmod 755 "$stage/payload/codeaw-bridge"
    if [ "$system" = Darwin ]; then
        [ -f "$stage/payload/codeaw-menu" ] && [ ! -L "$stage/payload/codeaw-menu" ] \
            || fail "Archive is missing the macOS menu bar helper. Use a newer macOS release."
        chmod 755 "$stage/payload/codeaw-menu"
    fi
    "$stage/payload/codeaw-bridge" --help >/dev/null \
        || fail "The downloaded bridge cannot run on this system; the previous install was kept."
    printf '%s\n' "$version $target" > "$stage/payload/.codeaw-installer"
    ln -s "$install_dir/codeaw-bridge" "$stage/command"
    if [ -d "$install_dir" ]; then mv -- "$install_dir" "$stage/previous"; fi
    mv -- "$stage/payload" "$install_dir"
    promoted=true
    mv -f -- "$stage/command" "$link"
    committed=true

    printf '\nInstalled: %s\n' "$link"
    case ":${PATH:-}:" in
        *":$bin_dir:"*) ;;
        *) printf 'Add this directory to your shell profile and current PATH:\n  export PATH=%s:"$PATH"\n' "$(quote "$bin_dir")" ;;
    esac
    printf '\nStart and pair your phone:\n  %s start\n' "$(quote "$link")"
    if [ "$system" = Darwin ]; then
        printf '\nStart the menu bar and optionally enable login startup:\n  %s tray\n  %s autostart install\n' "$(quote "$link")" "$(quote "$link")"
    else
        printf '\nOptional systemd user service:\n  %s service install\n  %s service start\n' "$(quote "$link")" "$(quote "$link")"
    fi
    printf '\nTailscale and your chosen ACP agents must be installed separately.\n'
    printf 'After an update, stop/start the bridge or run codeaw-bridge service restart to load the new executable.\n'
}

main "$@"
