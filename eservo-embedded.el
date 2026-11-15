;;; eservo-embedded.el --- the servo engine embedded as an Emacs module -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of eservo.  See the header of eservo.el for details.

;;; Commentary:

;; The servo web engine INSIDE the Emacs process.  A dynamic module
;; (libeservo.so, built from native/ in this repo) links the servo
;; engine and defines the `eservo-embedded-module-*' primitives; this
;; file is the thin Elisp backend that maps eservo's op set onto
;; them.  One process: no servo APK, no devtools port, no localhost
;; TCP, no child processes.  On Android the module lives inside the
;; Emacs app itself (see docs/EMBEDDED-SERVO.org for the packaging
;; paths and the rendering phases).
;;
;; Degrades cleanly: without the module, `eservo-embedded-available-p'
;; is nil and every op errors with an install hint.  The other
;; backends (cdp, servo devtools, adb) are untouched, so eservo core
;; keeps its pure-Elisp, no-dependency guarantee on every platform.
;;
;; Honest limits (v0 of the servo-linked module; the full pin list
;; lives in docs/EMBEDDED-SERVO.org): no cookie ops, so
;; `eservo-session-*' is unavailable on this backend.  Working when
;; linked: boot/stop/alive-p, goto (frame-heuristic load wait), url,
;; resize.  PIN-pending: screenshot (pixel readback), keys (keyboard
;; event construction), and the DOM ops snapshot/fill/click/extract/
;; evaluate/wait-selector (JS-eval seam) — each fails with an error
;; that names docs/EMBEDDED-SERVO.org.  In a build without the servo
;; feature every engine op signals the clear not-linked error — that
;; is the ABI surface the fast CI lane (native.yml, job `module')
;; proves against real Emacs 30.1.

;;; Code:

(require 'cl-lib)
(require 'eservo-backend)

;; The module defines these at runtime (native/src/lib.rs); declare the
;; two referenced directly so byte-compile stays warning-free.
(declare-function eservo-embedded-module-alive-p "eservo-embedded.el" () t)
(declare-function eservo-embedded-module-stop "eservo-embedded.el" () t)

(defvar eservo-embedded--loaded nil
  "Path (or t) recorded by `eservo-embedded-load-module'; informational.")

(defgroup eservo-embedded nil
  "The servo web engine embedded in Emacs as a dynamic module."
  :prefix "eservo-embedded-"
  :group 'eservo)

(defcustom eservo-embedded-module-file nil
  "Absolute path to the libeservo dynamic module.
When nil, `eservo-embedded-load-module' searches
`eservo-embedded-module-dirs' (plus built-in defaults); on Android it
also tries the bare name `libeservo' so the system linker can find a
library bundled in the app's nativeLibraryDir."
  :group 'eservo-embedded
  :type '(choice (const :tag "Search module directories" nil)
                 (file :tag "Absolute path to libeservo.so")))

(defcustom eservo-embedded-module-dirs nil
  "Extra directories searched for the libeservo module.
When nil the defaults are `modules' under `user-emacs-directory' and
`lib' under `eservo-state-dir'."
  :group 'eservo-embedded
  :type '(repeat directory))

(defcustom eservo-embedded-width 1024
  "Viewport width in pixels the embedded engine starts with."
  :group 'eservo-embedded
  :type 'natnum)

(defcustom eservo-embedded-height 768
  "Viewport height in pixels the embedded engine starts with."
  :group 'eservo-embedded
  :type 'natnum)

(defcustom eservo-embedded-user-agent nil
  "User-Agent string for the embedded engine, or nil for the default."
  :group 'eservo-embedded
  :type '(choice (const :tag "Engine default" nil) (string :tag "UA string")))

(defcustom eservo-embedded-resources-dir nil
  "Path to servo's resources/ tree, or nil to use engine defaults.
Servo wants fonts/config data at runtime; the Android packaging notes
in docs/EMBEDDED-SERVO.org explain where this lands on a phone."
  :group 'eservo-embedded
  :type '(choice (const :tag "Engine default" nil) (directory :tag "resources dir")))

(defcustom eservo-embedded-selector-timeout 10
  "Seconds `eservo-wait' gives a CSS selector to appear."
  :group 'eservo-embedded
  :type 'natnum)

(defun eservo-embedded-available-p ()
  "Return non-nil when the libeservo module is loaded and functional."
  (and (fboundp 'eservo-embedded-module-boot)
       (fboundp 'eservo-embedded-module-alive-p)
       t))

(defun eservo-embedded--module-name ()
  "Return the module's platform file name (libeservo + suffix)."
  (concat "libeservo" (or module-file-suffix ".so")))

(defun eservo-embedded--module-search-dirs ()
  "Directories searched for the module by `eservo-embedded-load-module'."
  (append
   (mapcar #'expand-file-name eservo-embedded-module-dirs)
   (list (expand-file-name "modules" user-emacs-directory)
         (expand-file-name "lib" eservo-state-dir))))

(defun eservo-embedded-load-module ()
  "Load the libeservo dynamic module into this Emacs.
Tries `eservo-embedded-module-file' first, then every directory in
`eservo-embedded--module-search-dirs'; on Android a bare-name load is
also attempted so a library bundled in the app's nativeLibraryDir
resolves through the system loader.  Returns non-nil on success;
errors with the install hint otherwise.  Idempotent: an already-loaded
module is a success."
  (interactive)
  (cond
   ((eservo-embedded-available-p) t)
   ((and eservo-embedded-module-file
         (file-exists-p eservo-embedded-module-file)
         (progn (module-load eservo-embedded-module-file) t))
    (setq eservo-embedded--loaded t))
   (t
    (let ((name (eservo-embedded--module-name))
          (found nil))
      (catch 'found
        (dolist (dir (eservo-embedded--module-search-dirs))
          (let ((path (expand-file-name name dir)))
            (when (file-exists-p path)
              (module-load path)
              (setq found path)
              (throw 'found path))))
        (when (eq system-type 'android)
          ;; The system loader knows the app's nativeLibraryDir; a
          ;; bare name is enough when the APK bundles the module.
          (condition-case nil
              (progn (module-load name) (setq found name)
                     (throw 'found name))
            (error nil))))
      (unless found
        (error "eservo: libeservo module not found (see docs/EMBEDDED-SERVO.org: \
build native/ or set eservo-embedded-module-file)"))
      (setq eservo-embedded--loaded found)))))

(defun eservo-embedded--fn (op)
  "Return the module function implementing OP (a symbol), or signal.
The error names the install doc so a user who never built native/
gets a next step, not a mystery void-function."
  (or (and (eservo-embedded-available-p)
           (intern-soft (concat "eservo-embedded-module-"
                                (symbol-name op))))
      (error "eservo: the embedded servo engine is not loaded \
(op `%s'; run M-x eservo-embedded-load-module, see docs/EMBEDDED-SERVO.org)"
             op)))

(defun eservo-embedded--call (op &rest args)
  "Invoke module OP with ARGS; module errors pass through."
  (apply (eservo-embedded--fn op) args))

;;; Backend ops (one function per eservo-backend.el slot)

(defun eservo-embedded--op-start (driver)
  "Boot the embedded engine for DRIVER."
  (eservo-embedded-load-module)
  (eservo-embedded--call
   'boot eservo-embedded-width eservo-embedded-height
   (or eservo-embedded-resources-dir "")
   (or eservo-embedded-user-agent ""))
  (setf (eservo--driver-url driver) "about:blank")
  t)

(defun eservo-embedded--op-stop (_driver)
  "Shut the embedded engine down; safe when never booted."
  (when (eservo-embedded-available-p)
    (ignore-errors (eservo-embedded-module-stop)))
  t)

(defun eservo-embedded--op-alive-p (_driver)
  "Non-nil when the engine thread is up."
  (and (eservo-embedded-available-p)
       (eservo-embedded-module-alive-p)))

(defun eservo-embedded--op-goto (driver url)
  "Navigate DRIVER to URL; the final URL (after redirects) is returned."
  (let ((final (eservo-embedded--call 'goto url)))
    (setf (eservo--driver-url driver) final)
    final))

(defun eservo-embedded--op-url (_driver)
  "Return the engine's current URL."
  (eservo-embedded--call 'url))

(defun eservo-embedded--op-snapshot (_driver)
  "Return the compact DOM outline with [N] refs."
  (eservo-embedded--call 'snapshot))

(defun eservo-embedded--op-fill (_driver selector text)
  "Set SELECTOR's value to TEXT (input events fired engine-side)."
  (eservo-embedded--call 'fill selector text))

(defun eservo-embedded--op-click (_driver ref)
  "Click element REF (a [N] snapshot ref or a CSS selector)."
  (eservo-embedded--call 'click ref))

(defun eservo-embedded--op-keys (_driver keys)
  "Send KEYS (tokens like \"RET\" or plain text) to the page."
  (eservo-embedded--call 'keys keys))

(defun eservo-embedded--op-wait (_driver spec)
  "Wait for SPEC: seconds (number) or a CSS selector string."
  (if (numberp spec)
      (progn (sleep-for spec) t)
    (eservo-embedded--call 'wait-selector
                           spec eservo-embedded-selector-timeout)))

(defun eservo-embedded--op-extract (_driver selector)
  "Return the text of all elements matching SELECTOR, joined."
  (eservo-embedded--call 'extract selector))

(defun eservo-embedded--op-screenshot (_driver file)
  "Write a PNG screenshot to FILE (bytes written module-side)."
  (eservo-embedded--call 'screenshot (expand-file-name file))
  file)

(defun eservo-embedded--op-evaluate (_driver js)
  "Evaluate JS in the page; the serialized result is returned."
  (eservo-embedded--call 'evaluate js))

(defun eservo-embedded--op-resize (_driver width height)
  "Resize the offscreen viewport to WIDTH x HEIGHT pixels."
  (eservo-embedded--call 'resize width height))

;;; Entry point

(defun eservo-embedded-make-backend ()
  "Return the embedded-servo backend (design: docs/EMBEDDED-SERVO.org)."
  (eservo-backend--make
   :name 'embedded
   :start #'eservo-embedded--op-start
   :stop #'eservo-embedded--op-stop
   :alive-p #'eservo-embedded--op-alive-p
   :goto #'eservo-embedded--op-goto
   :url #'eservo-embedded--op-url
   :snapshot #'eservo-embedded--op-snapshot
   :fill #'eservo-embedded--op-fill
   :click #'eservo-embedded--op-click
   :keys #'eservo-embedded--op-keys
   :wait #'eservo-embedded--op-wait
   :extract #'eservo-embedded--op-extract
   :screenshot #'eservo-embedded--op-screenshot
   :evaluate #'eservo-embedded--op-evaluate))

(provide 'eservo-embedded)
;;; eservo-embedded.el ends here
