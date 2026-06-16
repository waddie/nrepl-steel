// Copyright (c) 2026 Tom Waddington. MIT License — see LICENSE.

//! Per-session Steel engines for the nrepl-steel server, exposed over Steel's FFI.
//!
//! The pure-Scheme server cannot do everything an nREPL needs: enumerating a
//! session's global symbol table (for `completions`) is only reachable through
//! `Engine::readable_globals`, a Rust-only API, and steel-core's own
//! `(Engine::new)`/`run!` session values are `pub(crate)` so a dylib cannot
//! introspect them. So this dylib *owns* the session engines instead: each
//! [`SteelEngine`] wraps an independent [`steel::steel_vm::engine::Engine`] as an
//! opaque FFI value, and the Scheme evaluator seam (`evaluator.scm`) drives it.
//!
//! Exported functions (module `nrepl-steel-engine`, loaded as `libnrepl_steel_engine`):
//!
//! - `engine/new` → `SteelEngine` — fresh engine with the output-capture prelude
//!   already installed.
//! - `engine/eval` `(engine, code) ->` hash with keys `status`/`values`/`out`/
//!   `err`/`ex` — runs `code`, draining + resetting the capture ports.
//! - `engine/globals` `(engine, prefix) ->` list of `(name type)` pairs — the
//!   readable globals matching `prefix` (the Rust-only capability).
//! - `engine/symbol-info` `(engine, sym) ->` hash | `#f` — `name`/`type`/
//!   `arglists-str`/`doc` for a bound symbol, `#f` when unbound.
//! - `engine/close` `(engine) -> void` — explicit teardown (drop also reclaims).

mod engine;

use steel::{
    declare_module,
    steel_vm::ffi::{FFIModule, RegisterFFIFn},
};

declare_module!(create_module);

fn create_module() -> FFIModule {
    let mut module = FFIModule::new("nrepl-steel-engine");

    module
        .register_fn("engine/new", engine::SteelEngine::new)
        .register_fn("engine/eval", engine::SteelEngine::eval)
        .register_fn("engine/globals", engine::SteelEngine::globals)
        .register_fn("engine/symbol-info", engine::SteelEngine::symbol_info)
        .register_fn("engine/close", engine::SteelEngine::close);

    module
}
