#!/bin/sh
# Run the full Scheme test suite. Exits non-zero if any test fails.
# Wrapped in a timeout because the server integration test uses real sockets/threads;
# a clean run finishes in well under a second, so a generous cap only guards against a
# hang (which would otherwise wedge on Steel's join-threads-at-shutdown behaviour).
set -e
cd "$(dirname "$0")"

# The evaluation backend is the native nrepl-steel-engine dylib; the Scheme suite loads
# it via (#%require-dylib ...). Build + install it first (debug = fast compile).
./build.sh --debug

# The suite is written against the steel-test cog, which must be installed in
# $STEEL_HOME/cogs. It is a test-only dependency, so it is deliberately absent from
# cog.scm's `dependencies` (which would foist it on every consumer of the server).
if [ ! -f "${STEEL_HOME:-$HOME/.steel}/cogs/steel-test/test.scm" ]; then
  echo "run-tests.sh: steel-test is not installed in ${STEEL_HOME:-$HOME/.steel}/cogs." >&2
  echo "  install it with: forge pkg install --git https://github.com/waddie/steel-test" >&2
  exit 1
fi

if command -v timeout >/dev/null 2>&1; then
  exec timeout 120 steel test/run-tests.scm
elif command -v gtimeout >/dev/null 2>&1; then
  exec gtimeout 120 steel test/run-tests.scm
else
  exec steel test/run-tests.scm
fi
