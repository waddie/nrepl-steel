// Copyright (c) 2026 Tom Waddington. MIT License — see LICENSE.

//! A session engine the nrepl-steel server owns and drives over the FFI.

use abi_stable::std_types::RVec;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use steel::rvals::{Custom, SteelVal};
use steel::steel_vm::engine::Engine;
use steel::steel_vm::ffi::FFIValue;

/// Output-capture prelude, run once per engine at creation. Installs string ports
/// as the current output/error ports so evaluated code's writes are captured
/// instead of leaking to the server process's own stdout. The parameter bindings
/// persist across evals. (The pure-Scheme seam proved this is mandatory — see
/// progress-docs/spike-output-capture.md.)
const PRELUDE: &str = "(define __out (open-output-string)) \
     (define __err (open-output-string)) \
     (current-output-port __out) \
     (current-error-port __err)";

/// Drain both capture ports to strings, then recreate them — draining does NOT
/// clear a string port, so without the reset, output accumulates across evals.
/// Returns `(list out err)`.
const DRAIN_RESET: &str = "(let ((o (get-output-string __out)) \
           (e (get-output-string __err))) \
       (set! __out (open-output-string)) \
       (set! __err (open-output-string)) \
       (current-output-port __out) \
       (current-error-port __err) \
       (list o e))";

/// One isolated Steel engine, the backend for a single nREPL session.
///
/// Wrapped in `Arc<Mutex<…>>` so the value satisfies the `Send + Sync` bound the
/// FFI requires of opaque customs (steel built with `sync`), and so the server's
/// per-connection threads serialise access to a session's engine through the
/// lock. In normal single-client use the lock is uncontended: a session is only
/// ever touched by the one connection thread that owns it. A poisoned lock is
/// recovered with `into_inner` rather than unwrapped: a panic here would cross
/// the `abi_stable` FFI boundary and abort the host process.
pub struct SteelEngine {
    inner: Arc<Mutex<Engine>>,
}

impl Custom for SteelEngine {}

impl SteelEngine {
    /// Create a fresh engine with the capture prelude installed.
    pub fn new() -> SteelEngine {
        let mut engine = Engine::new();
        engine
            .compile_and_run_raw_program(PRELUDE)
            .expect("output-capture prelude must run in a fresh engine");
        SteelEngine {
            inner: Arc::new(Mutex::new(engine)),
        }
    }

    /// Run `code` and return a result hash with the keys the evaluator seam
    /// expects: `status` ("ok"|"error"), `values` (list of rendered value
    /// strings, void dropped), `out`, `err`, and `ex` (string on error, else #f).
    pub fn eval(&self, code: String) -> HashMap<String, FFIValue> {
        let mut engine = self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let result = engine.compile_and_run_raw_program(code);
        // Drain + reset the capture ports regardless of whether the eval threw.
        let (out, err) = engine
            .compile_and_run_raw_program(DRAIN_RESET)
            .ok()
            .as_deref()
            .map(extract_out_err)
            .unwrap_or_default();
        drop(engine);

        let mut h = HashMap::new();
        h.insert("out".to_string(), FFIValue::from(out));
        h.insert("err".to_string(), FFIValue::from(err));
        match result {
            Ok(values) => {
                // One rendered value per form, matching value->string
                // (`format!("{:?}", v)`); definitions/side-effects render as
                // "#<void>" and are dropped.
                let rendered: Vec<FFIValue> = values
                    .iter()
                    .map(|v| format!("{v:?}"))
                    .filter(|s| s != "#<void>")
                    .map(FFIValue::from)
                    .collect();
                h.insert("status".to_string(), FFIValue::from("ok".to_string()));
                h.insert("values".to_string(), FFIValue::Vector(rendered.into()));
                h.insert("ex".to_string(), FFIValue::BoolV(false));
            }
            Err(e) => {
                h.insert("status".to_string(), FFIValue::from("error".to_string()));
                h.insert("values".to_string(), FFIValue::Vector(RVec::new()));
                h.insert("ex".to_string(), FFIValue::from(e.to_string()));
            }
        }
        h
    }

    /// The readable globals whose names start with `prefix`, each as a
    /// `(name type)` pair. Enumerating the global symbol table is the one
    /// capability with no Scheme-level equivalent — the reason this dylib exists.
    pub fn globals(&self, prefix: &str) -> Vec<FFIValue> {
        let engine = self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut pairs: Vec<(String, &'static str)> = engine
            .readable_globals(0)
            .iter()
            .filter_map(|g| {
                let name = g.resolve();
                if name.starts_with(prefix) {
                    let ty = engine
                        .extract_value(name)
                        .ok()
                        .map_or("value", |v| type_of(&v));
                    Some((name.to_string(), ty))
                } else {
                    None
                }
            })
            .collect();
        pairs.sort_by(|a, b| a.0.cmp(&b.0));
        pairs
            .into_iter()
            .map(|(name, ty)| {
                FFIValue::Vector(vec![FFIValue::from(name), FFIValue::from(ty.to_string())].into())
            })
            .collect()
    }

    /// Symbol metadata for `sym`: a hash of `name`/`type`/`doc` (+ `arglists-str`
    /// / `arglists` when an arity is derivable), or `#f` when `sym` is unbound.
    /// Arity comes from the engine's own `arity?`; Steel does not store parameter
    /// names, so the arglist is synthesised positionally from the arity count.
    pub fn symbol_info(&self, sym: String) -> Option<HashMap<String, FFIValue>> {
        let mut engine = self
            .inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let value = engine.extract_value(&sym).ok()?;
        let ty = type_of(&value);
        let doc = doc_for(&mut engine, &value);
        let arglist = match engine.call_function_by_name_with_args("arity?", vec![value]) {
            Ok(SteelVal::IntV(n)) => usize::try_from(n).ok().map(synth_arglist),
            _ => None,
        };

        let mut h = HashMap::new();
        h.insert("name".to_string(), FFIValue::from(sym));
        h.insert("type".to_string(), FFIValue::from(ty.to_string()));
        h.insert("doc".to_string(), FFIValue::from(doc));
        if let Some(a) = arglist {
            h.insert("arglists-str".to_string(), FFIValue::from(a.clone()));
            h.insert("arglists".to_string(), FFIValue::from(a));
        }
        Some(h)
    }

    /// Explicit teardown hook. Dropping the engine (when the registry releases its
    /// reference) is what actually reclaims it; this exists so the seam's `close`
    /// has something to call. Takes `&self` because the FFI registers it as a
    /// method on the engine value; the empty body is the point.
    #[allow(clippy::unused_self)]
    pub fn close(&self) {}
}

/// Coarse symbol class for completion/lookup display.
fn type_of(value: &SteelVal) -> &'static str {
    match value {
        SteelVal::Closure(_)
        | SteelVal::FuncV(_)
        | SteelVal::MutFunc(_)
        | SteelVal::BuiltIn(_)
        | SteelVal::BoxedFunction(_) => "function",
        _ => "value",
    }
}

/// Render an `n`-ary arglist with placeholder names — Steel keeps the arity but
/// not the original parameter names, so `(_ _)` honestly means "two positional
/// args" without inventing names.
fn synth_arglist(n: usize) -> String {
    let args = vec!["_"; n].join(" ");
    format!("({args})")
}

/// The docstring for `value`, or "" if none.
///
/// Deliberately does NOT use `Engine::get_doc_for_identifier`. That routes through
/// `Compiler::get_doc`, which walks the builtin-module map and unconditionally
/// returns when it reaches the `steel/meta` module — so a native builtin whose doc
/// lives in a module ordered *after* `steel/meta` is never found. Module order is a
/// `HashMap` iteration order seeded fresh per `Engine` (i.e. per process), so the
/// same symbol's doc appears or vanishes from one server startup to the next.
///
/// Instead we query the two order-independent sources Steel's own `help` uses:
///   1. `#%native-fn-ptr-doc->string` — native builtins' metadata (FuncV/MutFunc/
///      `BuiltIn`); returns #f for closures.
///   2. `#%function-ptr-table-get` on `#%function-ptr-table` — the closure-id table
///      that holds docs for Scheme closures defined with `@doc` (stdlib `map`/
///      `filter`/… and user definitions).
fn doc_for(engine: &mut Engine, value: &SteelVal) -> String {
    if let Ok(SteelVal::StringV(s)) =
        engine.call_function_by_name_with_args("#%native-fn-ptr-doc->string", vec![value.clone()])
    {
        return s.to_string();
    }
    if let Ok(table) = engine.extract_value("#%function-ptr-table")
        && let Ok(SteelVal::StringV(s)) = engine
            .call_function_by_name_with_args("#%function-ptr-table-get", vec![table, value.clone()])
    {
        return s.to_string();
    }
    String::new()
}

/// Pull `(out err)` out of the `DRAIN_RESET` program's result list.
fn extract_out_err(vals: &[SteelVal]) -> (String, String) {
    if let Some(SteelVal::ListV(list)) = vals.last() {
        let mut it = list.iter();
        let out = it.next().and_then(as_string).unwrap_or_default();
        let err = it.next().and_then(as_string).unwrap_or_default();
        (out, err)
    } else {
        (String::new(), String::new())
    }
}

fn as_string(v: &SteelVal) -> Option<String> {
    if let SteelVal::StringV(s) = v {
        Some(s.to_string())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(h: &HashMap<String, FFIValue>) -> String {
        match h.get("status") {
            Some(FFIValue::StringV(s)) => s.to_string(),
            _ => panic!("no status"),
        }
    }

    fn values(h: &HashMap<String, FFIValue>) -> Vec<String> {
        match h.get("values") {
            Some(FFIValue::Vector(v)) => v
                .iter()
                .map(|x| match x {
                    FFIValue::StringV(s) => s.to_string(),
                    _ => panic!("non-string value"),
                })
                .collect(),
            _ => panic!("no values"),
        }
    }

    fn field<'a>(h: &'a HashMap<String, FFIValue>, k: &str) -> &'a str {
        match h.get(k) {
            Some(FFIValue::StringV(s)) => s.as_str(),
            other => panic!("field {k} not a string: {other:?}"),
        }
    }

    #[test]
    fn eval_returns_value() {
        let e = SteelEngine::new();
        let r = e.eval("(+ 1 2)".to_string());
        assert_eq!(status(&r), "ok");
        assert_eq!(values(&r), vec!["3"]);
    }

    #[test]
    fn definitions_persist_across_evals() {
        let e = SteelEngine::new();
        e.eval("(define foo 41)".to_string());
        let r = e.eval("(+ foo 1)".to_string());
        assert_eq!(values(&r), vec!["42"]);
    }

    #[test]
    fn output_is_captured_drained_and_reset() {
        let e = SteelEngine::new();
        let r1 = e.eval("(display \"hi\")".to_string());
        assert_eq!(field(&r1, "out"), "hi");
        // Draining resets the port: a no-output eval must not re-see "hi".
        let r2 = e.eval("(+ 1 1)".to_string());
        assert_eq!(field(&r2, "out"), "");
    }

    #[test]
    fn errors_map_to_status_error_and_ex() {
        let e = SteelEngine::new();
        let r = e.eval("(error \"boom\")".to_string());
        assert_eq!(status(&r), "error");
        assert!(values(&r).is_empty());
        assert!(field(&r, "ex").contains("boom"));
    }

    #[test]
    fn definitions_render_void_and_are_dropped() {
        let e = SteelEngine::new();
        let r = e.eval("(define x 1)".to_string());
        assert_eq!(status(&r), "ok");
        assert!(values(&r).is_empty());
    }

    #[test]
    fn globals_match_prefix_including_fresh_defines() {
        let e = SteelEngine::new();
        e.eval("(define foobar 1)".to_string());
        let names: Vec<String> = e
            .globals("fooba")
            .into_iter()
            .map(|v| match v {
                FFIValue::Vector(pair) => match &pair[0] {
                    FFIValue::StringV(s) => s.to_string(),
                    _ => panic!(),
                },
                _ => panic!(),
            })
            .collect();
        assert!(names.contains(&"foobar".to_string()), "got {names:?}");
    }

    #[test]
    fn symbol_info_for_builtin_and_unbound() {
        let e = SteelEngine::new();
        let info = e.symbol_info("map".to_string()).expect("map is bound");
        assert_eq!(field(&info, "name"), "map");
        assert_eq!(field(&info, "type"), "function");
        assert!(
            e.symbol_info("definitely-not-bound-xyz".to_string())
                .is_none()
        );
    }

    #[test]
    fn symbol_info_arglist_for_user_closure() {
        let e = SteelEngine::new();
        e.eval("(define (g a b) (+ a b))".to_string());
        let info = e.symbol_info("g".to_string()).expect("g is bound");
        assert_eq!(field(&info, "arglists-str"), "(_ _)");
    }

    #[test]
    fn doc_is_present_for_all_symbol_classes() {
        // `append` is a native builtin whose doc lives in a builtin module; under
        // the old `get_doc_for_identifier` path it was found only when its module
        // happened to sort before `steel/meta` in the per-engine HashMap order, so
        // it vanished on ~1 in 5 fresh processes. `map` is a Scheme closure whose
        // doc lives in the function-ptr table, and `gg` is a user `@doc` define.
        // `doc_for` must find all three regardless of module iteration order.
        let e = SteelEngine::new();
        let append = e
            .symbol_info("append".to_string())
            .expect("append is bound");
        assert!(
            field(&append, "doc").contains("Appends"),
            "native builtin doc missing: {:?}",
            field(&append, "doc")
        );
        let map = e.symbol_info("map".to_string()).expect("map is bound");
        assert!(!field(&map, "doc").is_empty(), "scheme builtin doc missing");

        e.eval("(@doc \"user docstring\" (define (gg x) x))".to_string());
        let gg = e.symbol_info("gg".to_string()).expect("gg is bound");
        assert_eq!(field(&gg, "doc"), "user docstring");
    }
}
