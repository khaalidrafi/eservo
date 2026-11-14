;;; eservo-backend.el --- pluggable backend dispatch for eservo -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of eservo.  See the header of eservo.el for details.

;;; Commentary:

;; eservo drives a browser through a small set of primitive operations
;; ("ops").  A backend is just a bundle of functions implementing those
;; ops; today there are two: `cdp' (Chromium/Chrome DevTools Protocol,
;; the default) and `adb' (best-effort Android via `adb shell').
;;
;; Keeping dispatch in ONE struct means the interactive commands in
;; eservo.el and the script runner in eservo-script.el never care which
;; backend is underneath.

;;; Code:

(require 'cl-lib)

(defgroup eservo-backend nil
  "Backend abstraction for eservo browser drivers."
  :group 'eservo)

(defcustom eservo-state-dir
  (expand-file-name
   "eservo"
   (file-name-as-directory
    (or (getenv "XDG_STATE_HOME") "~/.local/state")))
  "Directory for eservo's persistent local state (browser profile,
saved sessions).  Never committed to git; files with credentials get
mode 0600.  Uses XDG_STATE_HOME when set, so Termux/Android setups
work unchanged (HOME-based fallback)."
  :group 'eservo-backend
  :type 'directory)

(cl-defstruct (eservo-backend (:constructor eservo-backend--make))
  "One browser backend.  Every slot is a function taking the driver
`eservo--driver' as its first argument (unless noted) plus the extra
arguments listed below, or nil when the backend cannot provide the
op.  Keep this struct SMALL: if a new capability does not fit one of
these ops, question whether it belongs in eservo v0.1 at all."
  (name nil :documentation "Symbol naming the backend, e.g. `cdp'.")
  (start nil :documentation "(FN DRIVER) launch/connect; on success the backend fills its driver state.")
  (stop nil :documentation "(FN DRIVER) disconnect and terminate the browser.")
  (alive-p nil :documentation "(FN DRIVER) non-nil when the connection is usable.")
  (goto nil :documentation "(FN DRIVER URL) navigate the active page.")
  (url nil :documentation "(FN DRIVER) return the current URL string.")
  (snapshot nil :documentation "(FN DRIVER) return a compact text outline with element refs.")
  (fill nil :documentation "(FN DRIVER SELECTOR TEXT) set an input's value, firing input events (React-safe).")
  (click nil :documentation "(FN DRIVER REF) click an element by its numeric snapshot ref or a CSS selector.")
  (keys nil :documentation "(FN DRIVER KEYS) send key tokens like \"RET\", or type text.")
  (wait nil :documentation "(FN DRIVER WAIT-SPEC TIMEOUT) WAIT-SPEC is a number (seconds) or a CSS selector string.")
  (extract nil :documentation "(FN DRIVER SELECTOR) return text of all elements matching SELECTOR, joined.")
  (screenshot nil :documentation "(FN DRIVER FILE) best-effort PNG screenshot to FILE.")
  (evaluate nil :documentation "(FN DRIVER JS) evaluate JavaScript, return its value (or :no-value).")
  (cookies-get nil :documentation "(FN DRIVER) return list of cookie alists.")
  (cookies-set nil :documentation "(FN DRIVER COOKIE-ALIST-LIST) restore cookies."))

(defun eservo-backend-registered ()
  "Return the registry of known backends (symbol -> constructor plist)."
  '((cdp . eservo-cdp-make-backend)
    (adb . eservo-adb-make-backend)))

(defun eservo-backend-make (name)
  "Construct the backend named NAME (symbol) from the registry.
The matching `eservo-<name>.el' file is loaded on demand, so a user
who never touches the adb backend never pays for it."
  (let ((ctor (cdr (assq name (eservo-backend-registered)))))
    (unless ctor
      (error "eservo: unknown backend `%s' (known: %s)"
             name (mapconcat (lambda (e) (symbol-name (car e)))
                             (eservo-backend-registered) ", ")))
    (require (intern (concat "eservo-" (symbol-name name))) nil t)
    (funcall ctor)))

(cl-defstruct (eservo--driver (:constructor eservo--driver-make))
  "One live browser-driving session (backend + its runtime state).
There is normally exactly one, held in `eservo--current-driver';
interactive commands and scripts operate on it."
  (backend nil :documentation "The `eservo-backend' powering this driver.")
  (name nil :documentation "Printable name shown in buffers/logs.")
  (url nil :documentation "Current page URL as known to the backend.")
  (opts nil :documentation "Backend-specific plist (e.g. :proc, :ws, :port)."))

(defun eservo-backend-call (driver op &rest args)
  "Call backend OP on DRIVER with ARGS; signal a clear error if unsupported."
  (let* ((backend (eservo--driver-backend driver))
         (fn (funcall (intern (concat "eservo-backend-" (symbol-name op)))
                      backend)))
    (unless fn
      (error "eservo: backend `%s' does not support `%s'"
             (eservo-backend-name backend) op))
    (apply fn driver args)))

(provide 'eservo-backend)
;;; eservo-backend.el ends here
