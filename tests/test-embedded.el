;;; test-embedded.el --- tests for eservo-embedded.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; All tests are offline and hermetic: the module functions are STUBBED
;; by fset with exact save/restore, so the suite never needs libeservo
;; and never destroys real module definitions on a machine that has
;; them.  No network, no engine, no device.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eservo-backend)
(require 'eservo-embedded)

(defvar eservo-embedded-test--calls nil
  "Call log recorded by the stub module functions.")

(defconst eservo-embedded-test--stub-ops
  '(boot stop alive-p goto url snapshot fill click keys extract
    evaluate wait-selector screenshot resize)
  "Module ops the stub module implements (mirrors native/src/lib.rs).")

(defmacro eservo-embedded-test--with-stub-module (&rest body)
  "Run BODY with the module functions stubbed; restore exactly after.
Saves each symbol's current function cell (nil when undefined) and
puts it back, so a machine with the REAL module loaded is untouched."
  (declare (indent 0))
  `(let ((eservo-embedded-test--calls nil)
         (saved nil))
     (unwind-protect
         (progn
           (dolist (op ',eservo-embedded-test--stub-ops)
             (let ((sym (intern (concat "eservo-embedded-module-"
                                        (symbol-name op)))))
               (push (cons sym (and (fboundp sym) (symbol-function sym)))
                     saved)
               (fset sym
                     (lambda (&rest args)
                       (push (cons op args) eservo-embedded-test--calls)
                       (pcase op
                         ('boot t)
                         ('stop t)
                         ('alive-p t)
                         ('goto (car args))
                         ('url "https://example.com/final")
                         ('snapshot "[1] link \"Example\"")
                         ('screenshot
                          (with-temp-file (car args)
                            (insert "PNG-BYTES"))
                          (car args))
                         ('wait-selector t)
                         (_ t))))))
           ,@body)
       (dolist (cell saved)
         (if (cdr cell)
             (fset (car cell) (cdr cell))
           (fmakunbound (car cell)))))))

(ert-deftest eservo-embedded-backend-known ()
  "The backend registry resolves `embedded' and loads the file."
  (should (assq 'embedded (eservo-backend-registered)))
  (should (eservo-backend-make 'embedded)))

(ert-deftest eservo-embedded-op-coverage ()
  "Every op except cookies is provided by the embedded backend."
  (let ((backend (eservo-backend-make 'embedded)))
    (should (eq (eservo-backend-name backend) 'embedded))
    (dolist (slot '(start stop alive-p goto url snapshot fill click
                           keys wait extract screenshot evaluate))
      (should (funcall (intern (concat "eservo-backend-" (symbol-name slot)))
                       backend)))
    (should-not (eservo-backend-cookies-get backend))
    (should-not (eservo-backend-cookies-set backend))))

(ert-deftest eservo-embedded-missing-module-errors-with-hint ()
  "An op with no module function errors naming the install doc.
Uses an op the real module never defines, so this holds on machines
that DO have libeservo loaded too."
  (eservo-embedded-test--with-stub-module
    (let ((err (should-error
                (eservo-embedded--call 'no-such-op-ever "x"))))
      (should (string-match-p "EMBEDDED-SERVO.org"
                              (error-message-string err))))))

(ert-deftest eservo-embedded-dispatch-runs-ops ()
  "The full op cycle routes through the module functions."
  (eservo-embedded-test--with-stub-module
    (let* ((driver (eservo--driver-make
                    :backend (eservo-backend-make 'embedded)
                    :name "embedded")))
      (eservo-backend-call driver 'start)
      (should (equal (eservo-backend-call driver 'goto "https://example.com")
                     "https://example.com"))
      (should (equal (eservo--driver-url driver) "https://example.com"))
      (eservo-backend-call driver 'snapshot)
      (should (equal (eservo-backend-call driver 'url)
                     "https://example.com/final"))
      (let ((file (make-temp-file "eservo-embedded-test" nil ".png")))
        (eservo-backend-call driver 'screenshot file)
        (should (equal (with-temp-buffer
                         (insert-file-contents-literally file)
                         (buffer-string))
                       "PNG-BYTES")))
      (eservo-backend-call driver 'stop)
      ;; Order: boot, goto, snapshot, url, screenshot, stop.
      (should (equal (mapcar #'car (reverse eservo-embedded-test--calls))
                     '(boot goto snapshot url screenshot stop))))))

(ert-deftest eservo-embedded-wait-numeric-sleeps-not-calls ()
  "A numeric wait never touches the module."
  (eservo-embedded-test--with-stub-module
    (let ((driver (eservo--driver-make
                   :backend (eservo-backend-make 'embedded)
                   :name "embedded")))
      (should (eservo-backend-call driver 'wait 0.001))
      (should (equal (mapcar #'car (reverse eservo-embedded-test--calls))
                     nil)))))

(ert-deftest eservo-embedded-wait-selector-calls-module ()
  "A selector wait goes to the module with the configured timeout."
  (eservo-embedded-test--with-stub-module
    (let* ((driver (eservo--driver-make
                    :backend (eservo-backend-make 'embedded)
                    :name "embedded")))
      (eservo-backend-call driver 'wait ".answer")
      (should (equal (reverse eservo-embedded-test--calls)
                     '((wait-selector ".answer" 10)))))))

(ert-deftest eservo-embedded-available-p-follows-module ()
  "Availability is exactly: boot and alive-p are defined."
  (eservo-embedded-test--with-stub-module
    (should (eservo-embedded-available-p)))
  ;; Without the stub (CI never loads the module) the negative case
  ;; only holds when the real module is absent; skip when it is loaded.
  (unless (fboundp 'eservo-embedded-module-boot)
    (should-not (eservo-embedded-available-p))))

(ert-deftest eservo-embedded-stop-without-module-is-safe ()
  "Stopping with no module at all is a no-op, not an error."
  (unless (fboundp 'eservo-embedded-module-boot)
    (let ((driver (eservo--driver-make
                   :backend (eservo-backend-make 'embedded)
                   :name "embedded")))
      (should (eservo-backend-call driver 'stop)))))

(provide 'test-embedded)
;;; test-embedded.el ends here
