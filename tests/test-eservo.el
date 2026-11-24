;;; test-eservo.el --- tests for eservo.el (command layer) -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; All tests run against an injected STUB backend (no browser).  The
;; stub records every dispatched op in `eservo-test--calls' so tests
;; can assert what the interactive commands forwarded.

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
  "Run BODY with the stub backend registered and a clean driver state."
  `(let ((eservo-test--calls nil)
         (eservo-backend-registry '((stub . eservo-test--stub-backend)))
         (eservo--current-driver nil))
     ,@body))

(ert-deftest eservo-start-creates-current-driver ()
  "eservo-start must build a driver and call the backend start op."
  (eservo-test--with-stub
   (let ((driver (eservo-start 'stub)))
     (should (eq eservo--current-driver driver))
     (should (eq (eservo-backend-name (eservo--driver-backend driver)) 'stub))
     (should (member 'start eservo-test--calls))
     (eservo-stop)
     (should (null eservo--current-driver))
     (should (member 'stop eservo-test--calls)))))

(ert-deftest eservo-stop-without-driver-is-harmless ()
  "eservo-stop must not error when nothing is running."
  (eservo-test--with-stub
   (should (null (eservo-stop)))))

(ert-deftest eservo-start-twice-errors-unless-dead ()
  "A second eservo-start on a live driver must tell the user to stop."
  (eservo-test--with-stub
   (eservo-start 'stub)
   (let ((err (should-error (eservo-start 'stub))))
     (should (string-match-p "eservo-stop" (error-message-string err))))))

(ert-deftest eservo-commands-require-start ()
  "With `eservo-auto-start' nil commands fail with a helpful error.
(The default since the Emacshell field report is auto-start; the
explicit-only contract lives on for scripts via that variable.)"
  (eservo-test--with-stub
   (let ((eservo-auto-start nil))
     (let ((err (should-error (eservo-goto "https://x/"))))
       (should (string-match-p "eservo-start" (error-message-string err)))))))

(ert-deftest eservo-goto-dispatches-and-updates-url ()
  (eservo-test--with-stub
   (eservo-start 'stub)
   (should (equal (eservo-goto "https://example.com/") "https://example.com/"))
   (should (member '(goto "https://example.com/") eservo-test--calls))
   (should (equal (eservo-url) "https://stub.example/"))))

(ert-deftest eservo-snapshot-shows-and-returns-outline ()
  (eservo-test--with-stub
   (eservo-start 'stub)
   (let ((snap (eservo-snapshot)))
     (should (string= snap "[1] link \"Stub\""))
     (should (get-buffer "*eservo-snapshot*")))))

(ert-deftest eservo-fill-click-keys-dispatch ()
  (eservo-test--with-stub
   (eservo-start 'stub)
   (eservo-fill "textarea" "hello")
   (eservo-click 3)
   (eservo-click "button.send")
   (eservo-keys "hello RET")
   (should (member '(fill "textarea" "hello") eservo-test--calls))
   (should (member '(click 3) eservo-test--calls))
   (should (member '(click "button.send") eservo-test--calls))
   (should (member '(keys "hello RET") eservo-test--calls))))

(ert-deftest eservo-extract-returns-text ()
  (eservo-test--with-stub
   (eservo-start 'stub)
   (should (equal (eservo-extract ".answer") "stub-text"))
   (should (member 'extract eservo-test--calls))))

(ert-deftest eservo-screenshot-dispatches-file ()
  (eservo-test--with-stub
   (eservo-start 'stub)
   (should (equal (eservo-screenshot "/tmp/x.png") "/tmp/x.png"))
   (should (member '(screenshot "/tmp/x.png") eservo-test--calls))))

(ert-deftest eservo-agent-brief-has-menu-and-snapshot ()
  "The agent brief must contain the tool menu and the live snapshot."
  (eservo-test--with-stub
   (eservo-start 'stub)
   (let ((brief (eservo-agent-brief)))
     (should (string-match-p "eservo-goto" brief))
     (should (string-match-p "eservo-snapshot" brief))
     (should (string-match-p "eservo-agent-brief" brief))
     (should (string-match-p "\\[1\\] link \"Stub\"" brief))
     (should (get-buffer "*eservo-agent-brief*")))))

(provide 'test-eservo)
;;; test-eservo.el ends here
