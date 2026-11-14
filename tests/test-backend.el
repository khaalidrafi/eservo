;;; test-backend.el --- tests for eservo-backend.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eservo-backend)

;; A minimal in-memory backend used only to test the dispatch layer.
(defvar eservo-test--calls nil)

(defun eservo-test--make-stub-backend ()
  (eservo-backend--make
   :name 'stub
   :goto (lambda (driver url) (push (list 'goto url) eservo-test--calls)
           (setf (eservo--driver-url driver) url))
   ;; `extract' intentionally NOT implemented, to test the error path.
   ))

(ert-deftest eservo-backend-unknown-backend-errors ()
  "Asking for an unregistered backend must fail clearly."
  (should-error (eservo-backend-make 'does-not-exist)))

(ert-deftest eservo-backend-dispatch-calls-op ()
  "eservo-backend-call routes to the right closure."
  (let ((eservo-test--calls nil)
        (driver (eservo--driver-make
                 :backend (eservo-test--make-stub-backend) :name "stub")))
    (eservo-backend-call driver 'goto "https://example.com")
    (should (equal eservo-test--calls '((goto "https://example.com"))))
    (should (equal (eservo--driver-url driver) "https://example.com"))))

(ert-deftest eservo-backend-missing-op-errors ()
  "Calling an op the backend lacks must name backend and op."
  (let ((driver (eservo--driver-make
                 :backend (eservo-test--make-stub-backend) :name "stub")))
    (let ((err (should-error (eservo-backend-call driver 'extract ".x"))))
      (should (string-match-p "stub" (error-message-string err)))
      (should (string-match-p "extract" (error-message-string err))))))

(provide 'test-backend)
;;; test-backend.el ends here
