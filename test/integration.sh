#!/bin/sh
# Phase 7 acceptance gate: start the nrepl-steel server, drive it from a SEPARATE
# process (test/integration-client.scm) over a real TCP socket, and report.
#
# Separate processes are mandatory: an in-process client deadlocks with the server on
# the request/response loop. This is also why the integration test lives here rather
# than inside the single-process unit suite (run-tests.sh) — it spawns subprocesses
# and uses real sockets.
#
#   test/integration.sh [host:port]      (default 127.0.0.1:7899)
#
# Exits 0 if every client assertion passed, non-zero otherwise.
set -e
cd "$(dirname "$0")/.."

ADDR="${1:-127.0.0.1:7899}"
SRV_LOG="$(mktemp -t nrepl-steel-server.XXXXXX)"

# The client's assertions are written against the steel-test cog (test-only dependency,
# so not in cog.scm's `dependencies`).
if [ ! -f "${STEEL_HOME:-$HOME/.steel}/cogs/steel-test/test.scm" ]; then
  echo "integration.sh: steel-test is not installed in ${STEEL_HOME:-$HOME/.steel}/cogs." >&2
  echo "  install it with: forge pkg install --git https://github.com/waddie/steel-test" >&2
  exit 1
fi

cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  [ -n "$SRV_PID" ] && wait "$SRV_PID" 2>/dev/null || true
  rm -f "$SRV_LOG"
}
trap cleanup EXIT INT TERM

steel nrepl-steel.scm "$ADDR" >"$SRV_LOG" 2>&1 &
SRV_PID=$!

# Wait for the server to announce it is listening (up to ~5s).
i=0
while [ "$i" -lt 50 ]; do
  if grep -q "listening" "$SRV_LOG" 2>/dev/null; then break; fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "server exited before listening; log:" >&2
    cat "$SRV_LOG" >&2
    exit 1
  fi
  sleep 0.1
  i=$((i + 1))
done
if ! grep -q "listening" "$SRV_LOG" 2>/dev/null; then
  echo "server did not start listening within timeout; log:" >&2
  cat "$SRV_LOG" >&2
  exit 1
fi

echo "== driving $ADDR =="
# The client raises on failure -> non-zero rc, which propagates out via set -e.
steel test/integration-client.scm "$ADDR"
RC=$?
echo "== integration client rc=$RC =="
exit "$RC"
