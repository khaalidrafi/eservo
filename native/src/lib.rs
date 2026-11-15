//! libeservo -- the servo web engine embedded in the Emacs process.
//!
//! eservo is an EMBEDDED browser (Owner order, Discord 2026-11-15): no
//! separate servo APK, no devtools server, no second process.  Emacs
//! dlopens this module; the module runs servo on a private engine
//! thread and exposes the `eservo-embedded-module-*' primitives that
//! eservo-embedded.el maps onto the eservo backend op set.  On Android
//! the same module ships inside the Emacs app itself (packaging:
//! docs/EMBEDDED-SERVO.org).
//!
//! Build lanes (docs/EMBEDDED-SERVO.org):
//!
//! ```text
//! cargo build --release                    # zero-dep ABI module (fast CI lane)
//! cargo build --release --features servo   # link the real engine (pin lane)
//! ```
//!
//! The op set mirrors the Elisp backend 1:1 -- boot, stop, alive-p,
//! goto, url, snapshot, fill, click, keys, extract, evaluate,
//! wait-selector, screenshot, resize -- plus `version' and `linked-p'
//! for smoke tests and install UX.

mod emacs_api;
mod engine;

#[cfg(feature = "servo")]
mod servo_glue;

use std::os::raw::c_int;

use emacs_api::{EmacsEnv, EmacsValue, Env};
use engine::{EngineHandle, Reply, ReqOp};

use std::sync::Mutex;

static ENGINE: Mutex<Option<EngineHandle>> = Mutex::new(None);

const VERSION: &str = env!("CARGO_PKG_VERSION");

// ---- op plumbing (panic containment: a Rust bug must never crash Emacs)

fn locked_engine<R>(
    f: impl FnOnce(Option<&EngineHandle>) -> Result<R, String>,
) -> Result<R, String> {
    let guard = ENGINE
        .lock()
        .map_err(|_| "eservo: engine lock poisoned (a previous op panicked)".to_string())?;
    f(guard.as_ref())
}

fn call_op(op: ReqOp) -> Result<Reply, String> {
    std::panic::catch_unwind(|| {
        locked_engine(|handle| match handle {
            Some(h) => h.call(op),
            None => Err(
                "eservo: embedded engine not booted \
                 (M-x eservo-embedded-load-module, then the backend boots it)"
                    .to_string(),
            ),
        })
    })
    .unwrap_or_else(|_| {
        Err("eservo: engine op panicked (bug in libeservo)".to_string())
    })
}

fn do_boot(width: u32, height: u32, resources: String, user_agent: String) -> Result<(), String> {
    let mut guard = ENGINE
        .lock()
        .map_err(|_| "eservo: engine lock poisoned".to_string())?;
    if guard.is_some() {
        return Ok(()); // idempotent boot
    }
    let handle = engine::boot();
    match handle.call(ReqOp::Boot {
        width,
        height,
        resources,
        user_agent,
    }) {
        Ok(_) => {
            *guard = Some(handle);
            Ok(())
        }
        Err(e) => {
            // Dropping the handle shuts the thread down again.
            Err(e)
        }
    }
}

fn do_stop() -> Result<(), String> {
    let mut guard = ENGINE
        .lock()
        .map_err(|_| "eservo: engine lock poisoned".to_string())?;
    if let Some(mut handle) = guard.take() {
        handle.shutdown();
    }
    Ok(())
}

// ---- argument helpers

unsafe fn want_string(env: &Env, v: EmacsValue, what: &str) -> Result<String, String> {
    env.string_from_value(v)
        .ok_or_else(|| format!("eservo: {what} must be a string"))
}

unsafe fn want_u32(env: &Env, v: EmacsValue, what: &str) -> Result<u32, String> {
    env.extract_integer(v)
        .and_then(|n| u32::try_from(n).ok())
        .ok_or_else(|| format!("eservo: {what} must be a non-negative integer"))
}

unsafe fn want_u64(env: &Env, v: EmacsValue, what: &str) -> Result<u64, String> {
    env.extract_integer(v)
        .and_then(|n| u64::try_from(n).ok())
        .ok_or_else(|| format!("eservo: {what} must be a non-negative integer"))
}

unsafe fn reply_value(env: &Env, r: Reply) -> EmacsValue {
    match r {
        Reply::Bool(true) => env.intern("t"),
        Reply::Bool(false) => env.intern("nil"),
        Reply::Str(s) => env.make_string(&s),
        Reply::Unit => env.intern("t"),
    }
}

/// Run BODY; on Err signal an Elisp error (and return nil -- Emacs
/// discards the return value when a non-local exit is pending).
macro_rules! handle {
    ($env:ident, $body:expr) => {{
        let env = Env($env);
        match std::panic::catch_unwind(|| $body) {
            Ok(Ok(reply)) => reply_value(&env, reply),
            Ok(Err(msg)) => {
                env.signal_error(&msg);
                env.intern("nil")
            }
            Err(_) => {
                env.signal_error("eservo: libeservo panicked (bug; please report)");
                env.intern("nil")
            }
        }
    }};
}

// ---- the primitives

unsafe extern "C" fn h_version(
    env: *mut EmacsEnv,
    _n: isize,
    _a: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env(env);
    env.make_string(VERSION)
}

unsafe extern "C" fn h_linked_p(
    env: *mut EmacsEnv,
    _n: isize,
    _a: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    let env = Env(env);
    if cfg!(feature = "servo") {
        env.intern("t")
    } else {
        env.intern("nil")
    }
}

unsafe extern "C" fn h_boot(
    env: *mut EmacsEnv,
    _n: isize,
    args: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, {
        let e = Env(env);
        let args = std::slice::from_raw_parts(args, 4);
        let width = want_u32(&e, args[0], "width")?;
        let height = want_u32(&e, args[1], "height")?;
        let resources = want_string(&e, args[2], "resources dir")?;
        let user_agent = want_string(&e, args[3], "user agent")?;
        do_boot(width, height, resources, user_agent)?;
        Ok(Reply::Unit)
    })
}

unsafe extern "C" fn h_stop(
    env: *mut EmacsEnv,
    _n: isize,
    _a: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, { do_stop()?; Ok(Reply::Unit) })
}

unsafe extern "C" fn h_alive_p(
    env: *mut EmacsEnv,
    _n: isize,
    _a: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, { Ok(call_op(ReqOp::AliveP)?) })
}

unsafe extern "C" fn h_goto(
    env: *mut EmacsEnv,
    _n: isize,
    args: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, {
        let e = Env(env);
        let args = std::slice::from_raw_parts(args, 1);
        let url = want_string(&e, args[0], "url")?;
        call_op(ReqOp::Goto(url))
    })
}

unsafe extern "C" fn h_url(
    env: *mut EmacsEnv,
    _n: isize,
    _a: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, { call_op(ReqOp::Url) })
}

unsafe extern "C" fn h_snapshot(
    env: *mut EmacsEnv,
    _n: isize,
    _a: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, { call_op(ReqOp::Snapshot) })
}

unsafe extern "C" fn h_fill(
    env: *mut EmacsEnv,
    _n: isize,
    args: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, {
        let e = Env(env);
        let args = std::slice::from_raw_parts(args, 2);
        let selector = want_string(&e, args[0], "selector")?;
        let text = want_string(&e, args[1], "text")?;
        call_op(ReqOp::Fill { selector, text })
    })
}

unsafe extern "C" fn h_click(
    env: *mut EmacsEnv,
    _n: isize,
    args: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, {
        let e = Env(env);
        let args = std::slice::from_raw_parts(args, 1);
        let r = want_string(&e, args[0], "ref")?;
        call_op(ReqOp::Click(r))
    })
}

unsafe extern "C" fn h_keys(
    env: *mut EmacsEnv,
    _n: isize,
    args: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, {
        let e = Env(env);
        let args = std::slice::from_raw_parts(args, 1);
        let keys = want_string(&e, args[0], "keys")?;
        call_op(ReqOp::Keys(keys))
    })
}

unsafe extern "C" fn h_extract(
    env: *mut EmacsEnv,
    _n: isize,
    args: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, {
        let e = Env(env);
        let args = std::slice::from_raw_parts(args, 1);
        let selector = want_string(&e, args[0], "selector")?;
        call_op(ReqOp::Extract(selector))
    })
}

unsafe extern "C" fn h_evaluate(
    env: *mut EmacsEnv,
    _n: isize,
    args: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, {
        let e = Env(env);
        let args = std::slice::from_raw_parts(args, 1);
        let js = want_string(&e, args[0], "js")?;
        call_op(ReqOp::Evaluate(js))
    })
}

unsafe extern "C" fn h_wait_selector(
    env: *mut EmacsEnv,
    _n: isize,
    args: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, {
        let e = Env(env);
        let args = std::slice::from_raw_parts(args, 2);
        let selector = want_string(&e, args[0], "selector")?;
        let timeout = want_u64(&e, args[1], "timeout")?;
        call_op(ReqOp::WaitSelector { selector, timeout })
    })
}

unsafe extern "C" fn h_screenshot(
    env: *mut EmacsEnv,
    _n: isize,
    args: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, {
        let e = Env(env);
        let args = std::slice::from_raw_parts(args, 1);
        let path = want_string(&e, args[0], "file")?;
        call_op(ReqOp::Screenshot(path))
    })
}

unsafe extern "C" fn h_resize(
    env: *mut EmacsEnv,
    _n: isize,
    args: *mut EmacsValue,
    _d: *mut std::ffi::c_void,
) -> EmacsValue {
    handle!(env, {
        let e = Env(env);
        let args = std::slice::from_raw_parts(args, 2);
        let width = want_u32(&e, args[0], "width")?;
        let height = want_u32(&e, args[1], "height")?;
        call_op(ReqOp::Resize { width, height })
    })
}

// ---- module entry points

/// Emacs requires this symbol on every GPL-compatible dynamic module.
#[no_mangle]
pub extern "C" fn plugin_is_GPL_compatible() {}

#[no_mangle]
pub extern "C" fn emacs_module_init(env: *mut EmacsEnv) -> c_int {
    unsafe {
        let e = Env(env);
        e.defun(
            "eservo-embedded-module-version",
            0,
            0,
            h_version,
            "Return the libeservo module version string.",
        );
        e.defun(
            "eservo-embedded-module-linked-p",
            0,
            0,
            h_linked_p,
            "Non-nil when this libeservo was built with the servo engine feature.",
        );
        e.defun(
            "eservo-embedded-module-boot",
            4,
            4,
            h_boot,
            "Boot the embedded servo engine: (boot WIDTH HEIGHT RESOURCES-DIR USER-AGENT).\n\
             RESOURCES-DIR and USER-AGENT may be empty strings for engine defaults.",
        );
        e.defun(
            "eservo-embedded-module-stop",
            0,
            0,
            h_stop,
            "Shut the embedded engine down.  Safe when never booted.",
        );
        e.defun(
            "eservo-embedded-module-alive-p",
            0,
            0,
            h_alive_p,
            "Non-nil when the engine thread is up and booted.",
        );
        e.defun(
            "eservo-embedded-module-goto",
            1,
            1,
            h_goto,
            "Navigate the embedded engine to URL; returns the final URL.",
        );
        e.defun(
            "eservo-embedded-module-url",
            0,
            0,
            h_url,
            "Return the engine's current URL.",
        );
        e.defun(
            "eservo-embedded-module-snapshot",
            0,
            0,
            h_snapshot,
            "Return the compact DOM outline with [N] refs.",
        );
        e.defun(
            "eservo-embedded-module-fill",
            2,
            2,
            h_fill,
            "Set SELECTOR's input value to TEXT (input events fired engine-side).",
        );
        e.defun(
            "eservo-embedded-module-click",
            1,
            1,
            h_click,
            "Click the element named by REF (a [N] snapshot ref or CSS selector).",
        );
        e.defun(
            "eservo-embedded-module-keys",
            1,
            1,
            h_keys,
            "Send KEYS (tokens like \"RET\" or plain text) to the page.",
        );
        e.defun(
            "eservo-embedded-module-extract",
            1,
            1,
            h_extract,
            "Return the text of all elements matching SELECTOR, joined.",
        );
        e.defun(
            "eservo-embedded-module-evaluate",
            1,
            1,
            h_evaluate,
            "Evaluate JS in the page; the serialized result is returned.",
        );
        e.defun(
            "eservo-embedded-module-wait-selector",
            2,
            2,
            h_wait_selector,
            "Wait up to TIMEOUT seconds for SELECTOR to appear in the page.",
        );
        e.defun(
            "eservo-embedded-module-screenshot",
            1,
            1,
            h_screenshot,
            "Write a PNG screenshot to FILE.",
        );
        e.defun(
            "eservo-embedded-module-resize",
            2,
            2,
            h_resize,
            "Resize the offscreen viewport to WIDTH x HEIGHT pixels.",
        );
        // Provide the feature so `(require 'eservo-embedded-module)'
        // works after module-load.
        let provide = e.intern("provide");
        let feature = e.intern("eservo-embedded-module");
        e.funcall(provide, &[feature]);
        0
    }
}
