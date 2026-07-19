# nrepl-steel

An [nREPL](https://nrepl.org) server for the
[Steel](https://github.com/mattwparas/steel) Scheme runtime.

The protocol, transport and dispatch layers are pure Scheme; the evaluation
backend is a native Rust dylib (`libnrepl_steel_engine`) loaded over Steel’s FFI,
which owns one Steel engine per session and exposes eval plus the global symbol
table that `completions`/`lookup` need.

## Status

Working server covering the operations editors depend on:

| Op            | Notes                                                       |
| ------------- | ----------------------------------------------------------- |
| `clone`       | new session, an isolated Steel engine with a persistent env |
| `close`       | tear the session down                                       |
| `describe`    | advertises supported ops + `versions`                       |
| `eval`        | form-by-form, one `value` per form, batched `out`/`err`     |
| `load-file`   | evaluate the `file` field (file contents, per spec)         |
| `interrupt`   | best-effort, queued-only (see caveat)                       |
| `ls-sessions` | list active sessions                                        |
| `lookup`      | doc / arglists / type for a symbol (alias `info`)           |
| `completions` | prefix completion over the session’s bound globals          |

Each session is an isolated Steel engine; definitions persist across evals within
a session.

**Interrupt caveat:** cancellation is best-effort. A still-queued eval is dropped,
but an eval already running cannot be aborted.

## Installation

Requires Steel 0.8.2 (`steel` on PATH) and
[Forge](https://github.com/mattwparas/steel) (`forge` on PATH).

The evaluation backend is a native dylib: `forge` fetches a prebuilt one per
platform, or you build it yourself from a checkout with a Rust toolchain.

```sh
# From the repository – forge fetches the prebuilt dylib for your platform:
forge pkg install --git https://github.com/waddie/nrepl-steel

# Then add ~/.steel/bin to your PATH:
export PATH="$HOME/.steel/bin:$PATH"
```

This makes `nrepl-steel` available as a command and lets any Scheme script load
the library with `(require "nrepl-steel/nrepl-server/server.scm")`.

From a local checkout you must build + install the dylib yourself (it goes to
`$STEEL_HOME/native`, default `~/.steel/native`):

```sh
./build.sh                  # cargo build --release + install libnrepl_steel_engine
forge install /path/to/nrepl-steel
```

## Usage

```sh
nrepl-steel                         # listens on 127.0.0.1:7888
nrepl-steel 127.0.0.1:9000          # or pass host:port
nrepl-steel --no-port-file          # don't write .nrepl-port
```

Or from a checkout, without installing:

```sh
steel nrepl-steel.scm               # listens on 127.0.0.1:7888
steel nrepl-steel.scm 127.0.0.1:9000
```

It prints the listen address and parks until interrupted (Ctrl-C).

### The `.nrepl-port` file

On a successful bind the server writes the port to `.nrepl-port` in the current
directory. This is the convention nREPL tooling uses to find a running server without
being told its port: clients search the working directory and its ancestors. Clients
that rely on it, such as [nautilos](https://github.com/waddie/nautilos) and CIDER,
cannot reach the server without it. Pass `--no-port-file` to suppress the write.

The file is not removed on shutdown. Steel exposes no signal handler, so a `Ctrl-C`’d
server never gets to clean up and leaves the file behind.

## License

Copyright © 2026 Tom Waddington

Distributed under the MIT License. See LICENSE file for details.
