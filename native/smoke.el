;;; smoke.el --- CI smoke test for the libeservo module (fast lane) -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of eservo.  See the header of eservo.el for details.

;; Usage (CI only; needs a REAL emacs because it dlopens the module):
;;
;;   ESERVO_MODULE=/path/to/libeservo.so emacs --batch -l native/smoke.el
;;
;; Loads the ZERO-DEPENDENCY module build (no --features servo) into a
;; real Emacs and checks the ABI surface end to end: feature provided,
;; defalias'd primitives callable, string/bool returns, error
;; signaling, and the not-linked boot error.  Exits non-zero on any
;; failure; prints one "smoke ok" line on success.

;;; Code:

(let ((module (getenv "ESERVO_MODULE")))
  (unless (and module (file-exists-p module))
    (message "smoke FAIL: ESERVO_MODULE unset or missing: %s" module)
    (kill-emacs 1))
  (module-load module))

;; module-load must provide the feature.
(unless (featurep 'eservo-embedded-module)
  (message "smoke FAIL: module did not provide eservo-embedded-module")
  (kill-emacs 2))

;; Every primitive must be defalias'd and callable.
(dolist (prim '(eservo-embedded-module-version
                 eservo-embedded-module-linked-p
                 eservo-embedded-module-boot
                 eservo-embedded-module-stop
                 eservo-embedded-module-alive-p
                 eservo-embedded-module-goto
                 eservo-embedded-module-url
                 eservo-embedded-module-snapshot
                 eservo-embedded-module-fill
                 eservo-embedded-module-click
                 eservo-embedded-module-keys
                 eservo-embedded-module-extract
                 eservo-embedded-module-evaluate
                 eservo-embedded-module-wait-selector
                 eservo-embedded-module-screenshot
                 eservo-embedded-module-resize))
  (unless (fboundp prim)
    (message "smoke FAIL: primitive not defined: %s" prim)
    (kill-emacs 3)))

;; String return path.
(unless (stringp (eservo-embedded-module-version))
  (message "smoke FAIL: version is not a string")
  (kill-emacs 4))

;; This lane builds WITHOUT the servo feature.
(when (eservo-embedded-module-linked-p)
  (message "smoke FAIL: linked-p is non-nil in the no-servo lane")
  (kill-emacs 5))

;; Boolean return path.
(when (eservo-embedded-module-alive-p)
  (message "smoke FAIL: alive-p before boot")
  (kill-emacs 6))

;; Error-signaling path: boot in this lane must signal the clear
;; not-linked error, not return or crash Emacs.
(let ((signaled nil))
  (condition-case err
      (eservo-embedded-module-boot 64 64 "" "")
    (error
     (unless (string-match-p "WITHOUT the servo engine"
                             (error-message-string err))
       (message "smoke FAIL: boot error is not the not-linked hint: %S" err)
       (kill-emacs 7))
     (setq signaled t)))
  (unless signaled
    (message "smoke FAIL: boot did not signal in the no-servo lane")
    (kill-emacs 8)))

;; Stop must be safe without a booted engine.
(eservo-embedded-module-stop)

(message "smoke ok: libeservo %s (linked=%s)"
         (eservo-embedded-module-version)
         (eservo-embedded-module-linked-p))
(kill-emacs 0)

;;; smoke.el ends here
