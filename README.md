# nrepl-steel

An nREPL server for Steel Scheme.

## Requirements

Steel 0.8.2 (`steel` on PATH) and [Forge](https://github.com/mattwparas/steel) (`forge`
on PATH). The evaluation backend is a native dylib (`libnrepl_steel_engine`): `forge` downloads
a prebuilt one per platform, or you build it yourself from a checkout with a Rust
toolchain (`./build.sh`).

## Install

```sh
# Directly from the repository — forge fetches the prebuilt dylib for your platform:
forge pkg install --git https://github.com/waddie/nrepl-steel

# After install, add ~/.steel/bin to your PATH:
export PATH="$HOME/.steel/bin:$PATH"
```

This makes `nrepl-steel` globally available as a command and lets any Scheme
script load the server library with `(require "nrepl-steel/nrepl-server/server.scm")`.

From a local checkout you must build + install the dylib yourself (it goes to
`$STEEL_HOME/native`):

```sh
./build.sh                  # cargo build --release + install libnrepl_steel_engine
forge install /path/to/nrepl-steel
```

## Start a server

```sh
nrepl-steel                         # listens on 127.0.0.1:7888
nrepl-steel 127.0.0.1:9000          # or pass host:port
```

Or from a checkout, without installing:

```sh
steel nrepl-steel.scm               # listens on 127.0.0.1:7888
steel nrepl-steel.scm 127.0.0.1:9000
```

It prints the listen address and parks. Ctrl-C to stop.

Bind an explicit port. An ephemeral `:0` port cannot be reported back, because
`tcp-listener-local-addr` is not available in this Steel build.

## Connect

Point any nREPL client at the address. With nrepl.hx:

```
:nrepl-connect localhost:7888
```

Drive it from a separate process. A client running inside the same Steel runtime as
the server can deadlock on the request/response loop.

## Supported ops

`clone`, `describe`, `eval`, `load-file`, `close`, `ls-sessions`, `interrupt`,
`completions`, `lookup` (alias `info`).

Each session is an isolated Steel engine; definitions persist across evals within a
session. `eval` returns one `value` per form plus batched `out`/`err`, then `done`.
`load-file` evaluates the `file` field (the file _contents_, per the nREPL spec) just
like `eval`; the optional `file-path`/`file-name` metadata is accepted but ignored.
`completions` returns the session's bound symbols matching a `prefix`, as
`{candidate, type}` dicts. `lookup`/`info` returns an `info` dict (`name`, `type`,
`doc`, and `arglists`) for a symbol, or `no-info` if it is unbound.

Not implemented: streaming `out`, `stdin`/`need-input`. `interrupt` is queued-only.
Steel has no namespaces, so the `ns` field is omitted everywhere. Steel does not retain
parameter names, so `lookup` arglists are synthesised positionally (`(_ _)`) — the `doc`
string carries the real signature for builtins.

## Known limitations

- **`interrupt` is best-effort.** A still-queued eval is dropped; an eval already
  running cannot be aborted (Steel exposes no Scheme-level interrupt for a child engine.
- **Sessions persist independently of connections** (this is per the nREPL model - a
  client may resume a session id on a new connection). They are reclaimed only by an
  explicit `close`, so a client that repeatedly `clone`s and disconnects without
  closing will accumulate sessions until the server is restarted.
- **Abrupt reconnect can briefly stall.** If a client disconnects mid-exchange and a new
  client connects immediately, the new connection may stall for a few seconds while the
  dropped connection’s thread winds down. A single long-lived client (the intended
  editor use case) is unaffected.
- **Malformed frames drop the connection.** A bencode stream desync cannot be
  resynchronised, so the server closes that connection rather than guess; other
  connections are unaffected. Reconnect to continue.

## Run the tests

```sh
cargo test -p nrepl-steel-engine # Rust unit tests for the native engine backend

./run-tests.sh             # Scheme unit suite (builds + installs the dylib first):
                           # bencode, transport, evaluator/session, dispatch, serve-loop

test/integration.sh        # acceptance gate: starts a real server and drives it from
                           # a separate-process client over a socket (clone -> eval ->
                           # load-file -> completions -> lookup -> ls-sessions ->
                           # interrupt -> close)
```

The integration test is separate from the unit suite because it spawns subprocesses and
uses real sockets - a client sharing the server’s Steel runtime deadlocks (see below).

## License

Copyright © 2026 Tom Waddington

Distributed under the MIT License. See LICENSE file for details.
