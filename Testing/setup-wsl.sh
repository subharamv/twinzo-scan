#!/usr/bin/env bash
# One-shot setup for running the Twinzo Scan core tests from Windows via WSL.
#
# Run from inside WSL:
#   bash Testing/setup-wsl.sh
#
# Why WSL rather than Swift for Windows: the Windows toolchain has no linker or
# C runtime of its own and needs Visual Studio Build Tools (~3 GB) on top of the
# ~1 GB toolchain. On Linux it is one download and no MSVC.
set -u

SWIFT_VERSION="6.0.3"
DEST="/opt/swift"
COMPAT="/opt/swift-compat/lib"
POOL="http://archive.ubuntu.com/ubuntu/pool/main"

echo "=== dependencies ==="
sudo apt-get update -qq
# g++ rather than a pinned libstdc++-NN-dev: it resolves to whichever version
# this Ubuntu release ships, which is the part that changes between releases.
for pkg in binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 \
           libgcc-s1 libncurses-dev libpython3-dev libsqlite3-0 libxml2-dev \
           libz3-dev pkg-config tzdata unzip zlib1g-dev g++ curl; do
  sudo apt-get install -y -qq "$pkg" >/dev/null 2>&1 && printf '.' || printf 'X'
done
echo

echo "=== toolchain ==="
if [ -x "$DEST/usr/bin/swift" ]; then
  echo "already installed at $DEST"
else
  TARBALL="swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04.tar.gz"
  URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/${TARBALL}"
  mkdir -p "$HOME/swift-install" && cd "$HOME/swift-install" || exit 1
  # -C - resumes rather than restarting a 750 MB transfer after a dropped link.
  curl -fL -C - --retry 5 --progress-bar -o "$TARBALL" "$URL" || exit 1
  sudo rm -rf "$DEST" && sudo mkdir -p "$DEST"
  sudo tar -xzf "$TARBALL" -C "$DEST" --strip-components=1 || exit 1
fi

# Ubuntu releases newer than 24.04 have moved past the sonames this toolchain
# links against: libxml2 is now .so.16 (package libxml2-16), and the 24.04
# libxml2 in turn wants ICU 74. The soname bumps are deliberate ABI breaks, so
# symlinking the new versions would risk crashing inside the library rather than
# failing cleanly at load. Keep the originals in a private directory that only
# Swift sees, and leave the system's own copies alone.
echo "=== compatibility libraries ==="
sudo mkdir -p "$COMPAT"
fetch_deb() {
  local sub="$1" pattern="$2" url deb work
  url="${POOL}/${sub}/"
  # sort -V, not sort: lexically, 2.9.4 sorts after 2.9.14.
  deb=$(curl -sL --max-time 60 "$url" | grep -oE "$pattern" | sort -u | sort -V | tail -1)
  [ -z "$deb" ] && { echo "  no match: $pattern"; return 1; }
  work=$(mktemp -d) && cd "$work" || return 1
  echo "  $deb"
  curl -fsL --retry 3 -o "$deb" "${url}${deb}" || return 1
  dpkg-deb -x "$deb" ex || return 1
  find ex -name '*.so.*' -exec sudo cp -P {} "$COMPAT/" \; 2>/dev/null
}
if [ ! -f "$COMPAT/libxml2.so.2" ]; then
  fetch_deb "libx/libxml2" 'libxml2_2\.9\.[0-9]+[^"<>]*_amd64\.deb'
  fetch_deb "i/icu" 'libicu74_[^"<>]*_amd64\.deb'
else
  echo "  already present"
fi

export PATH="$DEST/usr/bin:$PATH"
export LD_LIBRARY_PATH="$COMPAT:${LD_LIBRARY_PATH:-}"

echo "=== verify ==="
MISSING=$(ldd "$DEST/usr/bin/swift-test" 2>/dev/null | grep 'not found' || true)
if [ -n "$MISSING" ]; then
  echo "unresolved libraries remain:"
  echo "$MISSING"
  echo "Fetch the matching 24.04 .deb into $COMPAT the same way as above."
  exit 1
fi

# Persist for future shells.
{
  echo "export PATH=$DEST/usr/bin:\$PATH"
  echo "export LD_LIBRARY_PATH=$COMPAT:\${LD_LIBRARY_PATH:-}"
} | sudo tee /etc/profile.d/swift.sh >/dev/null
sudo chmod +x /etc/profile.d/swift.sh

swift --version
echo
echo "Setup complete. Run the suite with:  bash Testing/run-tests.sh"
