;;; test-auto.el --- auto-start + auto backend resolution -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Covers the two UX rules added after the Emacshell field report:
;;
;;  1. `eservo-auto-start' (default t): any command needing a browser
;;     starts one instead of erroring "no browser started".
;;  2. `eservo-backend' = `auto' (the new default): the first backend
;;     that can actually run HERE is chosen, and when none can the
;;     error explains WHY each was rejected instead of blaming a
;;     missing chromium binary on a machine that never had one.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eservo)
(require 'eservo-backend)

(defvar eservo-test--calls nil)

(defun eservo-test--stub-backend ()
  (eservo-backend--make
   :name 'stub
   :start (lambda (_driver) (push 'start eservo-test--calls) t)
   :stop (lambda (_driver) (push 'stop eservo-test--calls) t)
   :alive-p (lambda (_driver) (member 'start eservo-test--calls))
   :goto (lambda (driver url)
           (push (list 'goto url) eservo-test--calls)
           (setf (eservo--driver-url driver) url)
           url)
   :url (lambda (_driver) "https://stub.example/")
   :snapshot (lambda (_driver) "[1] link \"Stub\"")
   :fill (lambda (_driver sel text)
           (push (list 'fill sel text) eservo-test--calls) t)
   :click (lambda (_driver ref)
            (push (list 'click ref) eservo-test--calls) t)
   :keys (lambda (_driver keys)
           (push (list 'keys keys) eservo-test--calls) t)
   :wait (lambda (_driver spec &optional _timeout)
           (push (list 'wait spec) eservo-test--calls) t)
   :extract (lambda (_driver _sel)
              (push 'extract eservo-test--calls) "stub-text")
   :screenshot (lambda (_driver file)
                 (push (list 'screenshot file) eservo-test--calls) file)))

(defmacro eservo-test--with-stub (&rest body)
  "Run BODY with the stub backend wired as the backend for AUTO."
  `(let ((eservo-test--calls nil)
         (eservo-backend-registry '((stub . eservo-test--stub-backend)))
         (eservo--current-driver nil)
         (eservo-auto-start t)
         (eservo-backend 'auto))
     (cl-letf (((symbol-function 'eservo--resolve-backend)
                (lambda () 'stub)))
       ,@body)))

(ert-deftest eservo-auto-start-starts-browser-on-first-command ()
  "With `eservo-auto-start' t, `eservo-goto' needs no prior start."
  (eservo-test--with-stub
   (eservo-goto "https://example/")
   (should (member 'start eservo-test--calls))
   (should (member '(goto "https://example/") eservo-test--calls))))

(ert-deftest eservo-auto-start-nil-restores-explicit-error ()
  "With `eservo-auto-start' nil the old error comes back."
  (eservo-test--with-stub
   (let ((eservo-auto-start nil))
     (should-error (eservo-goto "https://example/"))
     (should (null (member 'start eservo-test--calls))))))

(ert-deftest eservo-auto-start-replaces-dead-driver ()
  "A driver whose backend died is replaced, not an error."
  (eservo-test--with-stub
   (let ((driver (eservo-start 'stub)))
     (should (eq eservo--current-driver driver))
     ;; Simulate the backend dying: alive-p now returns nil.
     (setf (eservo-backend-alive-p (eservo--driver-backend driver))
           (lambda (_d) nil))
     (eservo-goto "https://example/")
     (should-not (eq eservo--current-driver driver))
     (should (eservo-backend-call eservo--current-driver 'alive-p)))))

(ert-deftest eservo-resolve-backend-honors-explicit-choice ()
  "`eservo-backend' set explicitly is returned as-is (no probing)."
  (let ((eservo-backend 'cdp))
    (should (eq (eservo--resolve-backend) 'cdp))))

(ert-deftest eservo-resolve-backend-auto-first-usable ()
  "`auto' returns the first backend without a reason."
  (cl-letf (((symbol-function 'eservo--backend-reason)
             (lambda (name)
               (pcase name (`embedded "no module") (`cdp nil))))
            (eservo-backend 'auto))
    (should (eq (eservo--resolve-backend) 'cdp))))

(ert-deftest eservo-resolve-backend-auto-error-lists-all-reasons ()
  "When nothing is usable the error names every rejected backend."
  (cl-letf (((symbol-function 'eservo--backend-reason)
             (lambda (name)
               (format "%s broken" name)))
            (eservo-backend 'auto))
    (let ((err (should-error (eservo--resolve-backend))))
      (pcase err
        (`(error ,msg)
         (should (string-match-p "embedded broken" msg))
         (should (string-match-p "cdp broken" msg))
         (should (string-match-p "servo broken" msg))
         (should (string-match-p "adb broken" msg)))))))

(ert-deftest eservo-start-accepts-explicit-backend-arg ()
  "An explicit BACKEND argument bypasses resolution (C-u flow)."
  (eservo-test--with-stub
   (let ((driver (eservo-start 'stub)))
     (should (eq (eservo-backend-name (eservo--driver-backend driver))
                 'stub)))))

;;; test-auto.el ends here
