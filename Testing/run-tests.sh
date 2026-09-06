#!/usr/bin/env bash
# Run the core test suite from WSL.
#
#   bash Testing/run-tests.sh              # run everything
#   bash Testing/run-tests.sh --mutate     # also verify the suite can fail
#
# Assumes Testing/setup-wsl.sh has been run once.
set -u

export PATH=/opt/swift/usr/bin:$PATH
export LD_LIBRARY_PATH="/opt/swift-compat/lib:${LD_LIBRARY_PATH:-}"

# Locate the repo whether invoked from Windows-mounted storage or a clone.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# SwiftPM does thousands of small file operations. Across WSL's 9p bridge to
# /mnt/c that is minutes; in the native filesystem it is seconds. Mirror first
# when the sources live on the Windows side.
case "$SRC" in
  /mnt/*)
    DST="$HOME/twinzo"
    mkdir -p "$DST"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete --exclude '.build' --exclude '.git' "$SRC/" "$DST/"
    else
      find "$DST" -mindepth 1 -maxdepth 1 ! -name '.build' -exec rm -rf {} +
      cp -r "$SRC"/. "$DST"/
    fi
    cd "$DST" || exit 1
    ;;
  *)
    cd "$SRC" || exit 1
    ;;
esac

if [ "${1:-}" = "--mutate" ]; then
  # A suite that has never failed proves nothing. Break the code deliberately
  # and confirm the right tests object.
  ICP="TwinzoScan/Sources/Alignment/PointToPlaneICP.swift"
  cp "$ICP" /tmp/icp.orig
  trap 'cp /tmp/icp.orig "$ICP"' EXIT

  echo "=== mutation: flip the sign of the ICP residual ==="
  sed -i 's/let rhs = -Double(r)/let rhs = Double(r)/' "$ICP"
  n=$(swift test 2>&1 | grep -cE "^Test Case .* failed" || true)
  echo "$n test(s) failed"
  [ "$n" -gt 0 ] && echo "OK: the suite detects a broken solver" \
                 || echo "PROBLEM: mutation went unnoticed"
  cp /tmp/icp.orig "$ICP"
  echo
fi

echo "=== swift test ==="
swift test 2>&1 | grep -E "^(Test Case .* (failed|passed)|Test Suite '(All tests|debug)|\s+Executed|error:|warning:)" \
  || swift test
