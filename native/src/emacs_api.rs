//! Hand-rolled bindings for the Emacs dynamic-module ABI (emacs-module.h).
//!
//! Zero dependencies on purpose: the `module` CI lane must
//! `cargo build --offline` and load the result into stock Emacs 30.1 to
//! prove the ABI glue -- before any servo code is involved.  Only the
//! env slots this module uses are declared.
//!
//! The struct below is a PREFIX of the real `emacs_env`: the declared
//! fields must match emacs-module.h exactly, in order.  eservo targets
//! Emacs 27.1+; the `size` versioning member has been the first field
//! since Emacs 27.  The CI smoke against a real Emacs is the gate that
//! catches any layout mistake: a wrong prefix means garbage function
//! pointers, which fails loudly on the first call.

use std::ffi::CString;
use std::os::raw::c_int;
use std::ptr;

/// `emacs_value`: an opaque handle to a Lisp object.
pub type EmacsValue = *mut std::ffi::c_void;
/// `ptrdiff_t`.
pub type Ptrdiff = isize;

/// `emacs_subroutine`: what `make_function` receives.
pub type Subroutine = unsafe extern "C" fn(
    env: *mut EmacsEnv,
    nargs: Ptrdiff,
    args: *mut EmacsValue,
    data: *mut std::ffi::c_void,
) -> EmacsValue;

/// `emacs_funcall_exit` (a plain C enum -> c_int by value).
pub type FuncallExit = c_int;

#[repr(C)]
pub struct EmacsEnv {
    pub size: Ptrdiff,
    pub make_global_ref: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> EmacsValue,
    pub free_global_ref: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue),
    pub non_local_exit_check: unsafe extern "C" fn(*mut EmacsEnv) -> FuncallExit,
    pub non_local_exit_signal:
        unsafe extern "C" fn(*mut EmacsEnv, symbol: EmacsValue, data: EmacsValue),
    pub non_local_exit_throw:
        unsafe extern "C" fn(*mut EmacsEnv, tag: EmacsValue, value: EmacsValue),
    pub non_local_exit_clear: unsafe extern "C" fn(*mut EmacsEnv),
    pub make_function: unsafe extern "C" fn(
        *mut EmacsEnv,
        min_arity: Ptrdiff,
        max_arity: Ptrdiff,
        sub: Subroutine,
        documentation: *const std::ffi::c_char,
        data: *mut std::ffi::c_void,
    ) -> EmacsValue,
    pub funcall:
        unsafe extern "C" fn(*mut EmacsEnv, nargs: Ptrdiff, args: *mut EmacsValue) -> EmacsValue,
    pub intern: unsafe extern "C" fn(*mut EmacsEnv, name: *const std::ffi::c_char) -> EmacsValue,
    pub type_of: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> EmacsValue,
    pub is_not_nil: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> bool,
    pub eq: unsafe extern "C" fn(*mut EmacsEnv, a: EmacsValue, b: EmacsValue) -> bool,
    pub extract_integer: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> i64,
    pub make_integer: unsafe extern "C" fn(*mut EmacsEnv, i64) -> EmacsValue,
    pub extract_float: unsafe extern "C" fn(*mut EmacsEnv, EmacsValue) -> f64,
    pub make_float: unsafe extern "C" fn(*mut EmacsEnv, f64) -> EmacsValue,
    pub make_string: unsafe extern "C" fn(*mut EmacsEnv, *const u8, Ptrdiff) -> EmacsValue,
    pub copy_string_contents:
        unsafe extern "C" fn(*mut EmacsEnv, EmacsValue, *mut u8, *mut Ptrdiff) -> bool,
}

/// Safe-ish wrapper: every method reads the env through the raw pointer
/// the Emacs loader handed `emacs_module_init`.  All methods are unsafe:
/// they must not be called while a non-local exit is pending (see
/// `signal_error`, which is the sanctioned way to leave one pending).
#[derive(Clone, Copy)]
pub struct Env(pub *mut EmacsEnv);

impl Env {
    pub unsafe fn intern(&self, name: &str) -> EmacsValue {
        let c = CString::new(name).expect("emacs symbol names contain no NUL");
        ((self.0).intern)(self.0, c.as_ptr())
    }

    pub unsafe fn make_string(&self, s: &str) -> EmacsValue {
        ((self.0).make_string)(self.0, s.as_ptr(), s.len() as Ptrdiff)
    }

    /// Lisp string -> Rust String via the two-call copy_string_contents
    /// protocol.  Returns None when the value is not a string.
    pub unsafe fn string_from_value(&self, v: EmacsValue) -> Option<String> {
        let mut len: Ptrdiff = 0;
        if !((self.0).copy_string_contents)(self.0, v, ptr::null_mut(), &mut len) && len == 0 {
            return None;
        }
        let mut buf = vec![0u8; len as usize];
        if !((self.0).copy_string_contents)(self.0, v, buf.as_mut_ptr(), &mut len) {
            return None;
        }
        buf.truncate(len as usize);
        if buf.last() == Some(&0) {
            buf.pop();
        }
        String::from_utf8(buf).ok()
    }

    pub unsafe fn make_integer(&self, n: i64) -> EmacsValue {
        ((self.0).make_integer)(self.0, n)
    }

    pub unsafe fn extract_integer(&self, v: EmacsValue) -> Option<i64> {
        match ((self.0).non_local_exit_check)(self.0) {
            0 => Some(((self.0).extract_integer)(self.0, v)),
            _ => None,
        }
    }

    pub unsafe fn is_not_nil(&self, v: EmacsValue) -> bool {
        ((self.0).is_not_nil)(self.0, v)
    }

    /// funcall FN with ARGS (FN not included in ARGS).
    pub unsafe fn funcall(&self, f: EmacsValue, args: &[EmacsValue]) -> EmacsValue {
        let mut all = Vec::with_capacity(args.len() + 1);
        all.push(f);
        all.extend_from_slice(args);
        ((self.0).funcall)(self.0, all.len() as Ptrdiff, all.as_mut_ptr())
    }

    /// Signal an Elisp `(error MSG)' from the module.  The data list is
    /// built while NO non-local exit is pending (legal), then the exit
    /// is raised -- the documented pattern.  After calling this, return
    /// immediately; the handler's return value is discarded.
    pub unsafe fn signal_error(&self, msg: &str) {
        let s = self.make_string(msg);
        let data = self.funcall(self.intern("list"), &[s]);
        let sym = self.intern("error");
        ((self.0).non_local_exit_signal)(self.0, sym, data);
    }

    /// Define an Elisp function NAME (min..max args) backed by F and
    /// make it globally reachable via defalias.
    pub unsafe fn defun(
        &self,
        name: &str,
        min_arity: Ptrdiff,
        max_arity: Ptrdiff,
        f: Subroutine,
        doc: &str,
    ) {
        let doc_c = CString::new(doc).expect("docstrings contain no NUL");
        let fv = ((self.0).make_function)(
            self.0,
            min_arity,
            max_arity,
            f,
            doc_c.as_ptr(),
            ptr::null_mut(),
        );
        let sym = self.intern(name);
        let defalias = self.intern("defalias");
        self.funcall(defalias, &[sym, fv]);
    }
}
