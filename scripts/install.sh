#!/usr/bin/env sh
set -eu

repo="renatogalera/kill-port"
base_url="https://github.com/${repo}/releases/latest/download"

log() {
    printf '%s\n' "$*"
}

fail() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

download() {
    url=$1
    output=$2

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 15 -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$output" "$url"
    else
        fail "missing curl or wget"
    fi
}

detect_asset() {
    os=$(uname -s)
    arch=$(uname -m)

    case "$os" in
        Linux) platform="linux" ;;
        Darwin) platform="macos" ;;
        *) fail "unsupported operating system: $os" ;;
    esac

    case "$arch" in
        x86_64 | amd64) cpu="amd64" ;;
        arm64 | aarch64) cpu="arm64" ;;
        *) fail "unsupported architecture: $arch" ;;
    esac

    printf 'kill-port-%s-%s' "$platform" "$cpu"
}

checksum_file() {
    archive=$1
    checksum=$2

    expected=$(awk '{print tolower($1)}' "$checksum")

    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$archive" | awk '{print tolower($1)}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$archive" | awk '{print tolower($1)}')
    else
        log "sha256 tool not found; skipping checksum verification"
        return
    fi

    [ "$expected" = "$actual" ] || fail "checksum mismatch"
}

copy_binary() {
    source=$1
    destination=$2

    if command -v install >/dev/null 2>&1; then
        install -m 755 "$source" "$destination"
    else
        cp "$source" "$destination"
        chmod 755 "$destination"
    fi
}

install_to_dir() {
    source=$1
    target_dir=$2

    if mkdir -p "$target_dir" 2>/dev/null && [ -w "$target_dir" ]; then
        copy_binary "$source" "$target_dir/kill-port"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo mkdir -p "$target_dir"
        if command -v install >/dev/null 2>&1; then
            sudo install -m 755 "$source" "$target_dir/kill-port"
        else
            sudo cp "$source" "$target_dir/kill-port"
            sudo chmod 755 "$target_dir/kill-port"
        fi
        return 0
    fi

    return 1
}

need uname
need tar
need mktemp

asset=$(detect_asset)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

archive="$tmp_dir/${asset}.tar.gz"
checksum="$tmp_dir/${asset}.tar.gz.sha256"

log "Downloading ${asset}.tar.gz"
download "$base_url/${asset}.tar.gz" "$archive"

if download "$base_url/${asset}.tar.gz.sha256" "$checksum"; then
    checksum_file "$archive" "$checksum"
fi

tar -xzf "$archive" -C "$tmp_dir"
binary="$tmp_dir/$asset/kill-port"
[ -f "$binary" ] || fail "archive does not contain kill-port"

if [ "${KILL_PORT_INSTALL_DIR:-}" ]; then
    install_dir=$KILL_PORT_INSTALL_DIR
    install_to_dir "$binary" "$install_dir" || fail "could not install to $install_dir"
else
    install_dir="/usr/local/bin"
    if ! install_to_dir "$binary" "$install_dir"; then
        install_dir="$HOME/.local/bin"
        mkdir -p "$install_dir"
        copy_binary "$binary" "$install_dir/kill-port"
    fi
fi

case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) log "Installed to $install_dir, but that directory is not in PATH for this shell" ;;
esac

log "Installed kill-port to $install_dir/kill-port"
"$install_dir/kill-port" --version
