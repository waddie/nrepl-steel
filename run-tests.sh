#!/bin/sh
# Run the full Scheme test suite. Exits non-zero if any test fails.
# Wrapped in a timeout because the server integration test uses real sockets/threads;
# a clean run finishes in well under a second, so a generous cap only guards against a
# hang (which would otherwise wedge on Steel's join-threads-at-shutdown behaviour).
set -e
cd "$(dirname "$0")"
if command -v timeout >/dev/null 2>&1; then
  exec timeout 120 steel test/run-tests.scm
elif command -v gtimeout >/dev/null 2>&1; then
  exec gtimeout 120 steel test/run-tests.scm
else
  exec steel test/run-tests.scm
fi
