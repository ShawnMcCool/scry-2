#!/bin/sh
# Scry 2 — bootstrap installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ShawnMcCool/scry-2/main/installer/install.sh | sh
#
# Resolves the latest GitHub Release, downloads the platform-appropriate
# release archive, verifies it against the shipped SHA256SUMS file, and
# hands off to the bundled `install` script inside the extracted tree.
#
# Optional flags:
#   --version <vX.Y.Z>   Install a specific release tag instead of latest.
#
# Supported platforms:
#   Linux x86_64 (glibc)   — XDG autostart + tray
#   macOS aarch64 (Apple Silicon) — LaunchAgent + tray
#
# Windows users: use the MSI from the GitHub Releases page instead.

set -eu

GITHUB_REPO="ShawnMcCool/scry-2"

die()    { printf 'Error: %s\n' "$1" >&2; exit 1; }
banner() { printf '==> %s\n' "$1"; }
need()   { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

# Validate a tag string against the canonical release shape. Rejected
# strings never reach URL construction or filesystem paths — shell
# `case` globs can't enforce digits-only, which opens injections like
# "v0.7.1; rm".
validate_tag() {
    printf '%s' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$'
}

# ---- platform detection ---------------------------------------------------
#
# Release archives are published per-platform by the CI matrix in
# .github/workflows/release.yml. The asset names the matrix produces
# are the source of truth; we mirror them here:
#
#   linux-x86_64   — Ubuntu runner, glibc
#   macos-aarch64  — macOS runner, Apple Silicon
#
# A different CPU/OS combination means no published archive.

os_arch=""
case "$(uname -s)" in
    Linux)
        case "$(uname -m)" in
            x86_64|amd64) os_arch="linux-x86_64" ;;
            *) die "Unsupported Linux CPU: $(uname -m). Only x86_64 has a published archive." ;;
        esac

        if [ -f /etc/os-release ] && grep -qi 'alpine\|musl' /etc/os-release; then
            die "musl libc is not supported. Releases are built against glibc."
        fi
        ;;
    Darwin)
        case "$(uname -m)" in
            arm64|aarch64) os_arch="macos-aarch64" ;;
            *) die "Unsupported macOS CPU: $(uname -m). Releases are built for Apple Silicon (arm64) only." ;;
        esac
        ;;
    *)
        die "Unsupported OS: $(uname -s). Linux and macOS only — Windows users install via the MSI from the GitHub Releases page."
        ;;
esac

# sha256sum on Linux, shasum on macOS — both produce the same output
# format, so we alias one to a common helper.
if command -v sha256sum >/dev/null 2>&1; then
    sha256_check() { sha256sum -c -; }
elif command -v shasum >/dev/null 2>&1; then
    sha256_check() { shasum -a 256 -c -; }
else
    die "Neither sha256sum nor shasum is available. Install one and retry."
fi

need curl
need tar

# ---- arg parsing ----------------------------------------------------------

requested_tag=""
# Unknown flags get forwarded to the bundled installer so
# `curl … | sh -s -- --some-flag` keeps working without the bootstrap
# tracking every flag.
forward_args=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) requested_tag="$2"; shift 2 ;;
        --version=*) requested_tag="${1#--version=}"; shift ;;
        --help|-h)
            sed -n '2,/^$/p' "$0" 2>/dev/null | sed 's/^# //;s/^#$//' || true
            exit 0
            ;;
        *)
            if [ -z "$forward_args" ]; then
                forward_args="$1"
            else
                forward_args="$forward_args $1"
            fi
            shift
            ;;
    esac
done

# ---- resolve tag ----------------------------------------------------------

if [ -n "$requested_tag" ]; then
    tag="$requested_tag"
    banner "Using requested release: $tag"
else
    banner "Resolving latest release"
    api_url="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
    tag=$(curl -fsSL "$api_url" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$tag" ] || die "Could not resolve latest release tag from $api_url"
    banner "Latest is $tag"
fi

validate_tag "$tag" || die "Rejected malformed tag: $tag"

tarball="scry_2-${tag}-${os_arch}.tar.gz"
sha_file="scry_2-${tag}-${os_arch}-SHA256SUMS"
base_url="https://github.com/$GITHUB_REPO/releases/download/$tag"

# ---- download + verify ----------------------------------------------------

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

banner "Downloading $tarball"
curl -fsSL --progress-bar -o "$tmpdir/$tarball" "$base_url/$tarball"
curl -fsSL               -o "$tmpdir/$sha_file" "$base_url/$sha_file"

banner "Verifying checksum"
(cd "$tmpdir" && grep " $tarball\$" "$sha_file" | sha256_check) \
    || die "Checksum verification failed — refusing to install."

# ---- extract + hand off ---------------------------------------------------

banner "Extracting"
mkdir -p "$tmpdir/extract"
# Release tarballs wrap everything in a top-level directory named
# `scry_2-<tag>-<platform>/`. Strip that wrapper so the bundled
# installer lives predictably at $tmpdir/extract/install.
tar -xzf "$tmpdir/$tarball" --strip-components=1 -C "$tmpdir/extract"

bundled_installer="$tmpdir/extract/install"
[ -x "$bundled_installer" ] || die "Archive missing ./install — was this built before the install flow shipped?"

banner "Handing off to bundled installer"
# shellcheck disable=SC2086 # intentional word-split of forward_args
exec "$bundled_installer" $forward_args
