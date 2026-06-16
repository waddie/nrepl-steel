#!/bin/sh
# Build the nrepl-steel-engine dylib and install it where Steel's loader finds it.
#
#   ./build.sh            release build (default)
#   ./build.sh --debug    debug build (faster compile, used by the test suite)
#
# The dylib is the server's evaluation backend (one Steel engine per session);
# evaluator.scm loads it via (#%require-dylib "libnrepl_steel_engine" ...). Steel
# resolves that name against $STEEL_HOME/native (default ~/.steel/native).
set -e
cd "$(dirname "$0")"

profile=release
cargo_flag=--release
if [ "$1" = "--debug" ]; then
  profile=debug
  cargo_flag=
fi

# shellcheck disable=SC2086
cargo build $cargo_flag -p nrepl-steel-engine

# Platform dylib extension.
case "$(uname -s)" in
  Darwin) ext=dylib ;;
  Linux)  ext=so ;;
  *)      ext=dll ;;
esac

native="${STEEL_HOME:-$HOME/.steel}/native"
mkdir -p "$native"
cp "target/$profile/libnrepl_steel_engine.$ext" "$native/"
echo "installed libnrepl_steel_engine.$ext -> $native"
