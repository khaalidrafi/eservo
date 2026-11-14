;;; test-script.el --- tests for eservo-script.el (no AI, no browser) -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eservo)
(require 'eservo-backend)
(require 'eservo-session)
(require 'eservo-script)

(defvar eservo-test--calls nil)
(defvar eservo-test--extract-text "the-answer\nline two")

(defun eservo-test--script-stub-backend ()
  (eservo-backend--make
   :name 'stub
   :start (lambda (_d) (push 'start eservo-test--calls) t)
   :stop (lambda (_d) (push 'stop eservo-test--calls) t)
   :alive-p (lambda (_d) (member 'start eservo-test--calls))
   :goto (lambda (driver url)
           (push (list 'goto url) eservo-test--calls)
           (setf (eservo--driver-url driver) url)
           url)
   :url (lambda (_d) "https://stub.example/")
   :snapshot (lambda (_d) "[1] link \"Stub\"")
   :fill (lambda (_d sel text)
           (push (list 'fill sel text) eservo-test--calls) t)
   :click (lambda (_d ref) (push (list 'click ref) eservo-test--calls) t)
   :keys (lambda (_d keys) (push (list 'keys keys) eservo-test--calls) t)
   :wait (lambda (_d spec &optional _to)
           (push (list 'wait spec) eservo-test--calls) t)
   :extract (lambda (_d sel) (push (list 'extract sel) eservo-test--calls)
              eservo-test--extract-text)
   :screenshot (lambda (_d f) (push (list 'screenshot f) eservo-test--calls) f)
   :cookies-get (lambda (_d) '(((name . "sid") (value . "v"))))
   :cookies-set (lambda (_d c) (push (list 'cookies-set c) eservo-test--calls) t)
   :evaluate (lambda (_d js)
               (cond ((string-search "location.origin" js)
                      (json-encode `((origin . "https://stub.example")
                                     (local . (("k" . "v"))))))
                     (t :no-value)))))

(defmacro eservo-test--with-script-stub (&rest body)
  `(let ((eservo-test--calls nil)
         (eservo-backend 'stub)
         (eservo-backend-registry
          '((stub . eservo-test--script-stub-backend)))
         (eservo--current-driver nil)
         (eservo-session-dir (make-temp-file "eservo-sess" t)))
     (unwind-protect ,@body
       (ignore-errors (eservo-stop))
       (ignore-errors (delete-directory eservo-session-dir t)))))

(defun eservo-test--temp-file (content &optional ext)
  (let ((f (make-temp-file "eservo-script" nil ext)))
    (with-temp-file f (insert content))
    f))

(ert-deftest eservo-script-parses-sexp-lists ()
  "A file starting with ( is read as one or more sexp steps."
  (let* ((file (eservo-test--temp-file
                "((goto \"https://a.example\")\n (wait 1))\n"))
         (steps (eservo-script--parse file)))
    (should (equal steps '((goto "https://a.example") (wait 1))))))

(ert-deftest eservo-script-parses-org-one-step-per-line ()
  "Org files: skip headings/comments, one sexp step per line."
  (let* ((file (eservo-test--temp-file
                "* my task script\n"
                ".org"))
         (_ (with-temp-file file
              (insert "* My script\n"
                      "# a comment\n"
                      "- (goto \"https://a.example\")\n"
                      "(fill \"textarea\" \"hi there\")\n"
                      "+ (wait 0)\n")))
         (steps (eservo-script--parse file)))
    (should (equal steps '((goto "https://a.example")
                           (fill "textarea" "hi there")
                           (wait 0))))))

(ert-deftest eservo-script-run-executes-steps-in-order ()
  "The canonical agent-less chat flow works end to end."
  (eservo-test--with-script-stub
   (let* ((out (make-temp-file "eservo-out"))
          (file (eservo-test--temp-file
                 (format "((goto \"https://stub.example\")\n (fill \"textarea\" \"hello\")\n (keys \"RET\")\n (wait 1)\n (extract \".answer\")\n (write \"%s\"))\n"
                         out))))
     (eservo-script-run file)
     ;; dispatch order (stub pushes newest first); `start' is pushed
     ;; as a bare symbol by the stub, so normalise elements first.
     (let ((kinds (mapcar (lambda (x) (if (consp x) (car x) x))
                          eservo-test--calls)))
       (should (equal kinds
                      '(extract wait keys fill goto start))))
     (should (member '(fill "textarea" "hello") eservo-test--calls))
     ;; the extract result landed in the output file
     (with-temp-buffer
       (insert-file-contents out)
       (should (string= (buffer-string) eservo-test--extract-text))))))

(ert-deftest eservo-script-run-auto-starts-browser ()
  "A script may be run with no driver; eservo-start happens implicitly."
  (eservo-test--with-script-stub
   (let ((file (eservo-test--temp-file "((goto \"https://x.example\"))\n")))
     (should (eservo-script-run file))
     (should (member 'start eservo-test--calls)))))

(ert-deftest eservo-script-unknown-step-errors ()
  "Unknown ops fail loudly naming the step."
  (eservo-test--with-script-stub
   (let ((file (eservo-test--temp-file "((fly \"https://x\"))\n")))
     (let ((err (should-error (eservo-script-run file))))
       (should (string-match-p "fly" (error-message-string err)))))))

(ert-deftest eservo-script-write-without-extract-errors ()
  "`write' needs a previous `extract' result."
  (eservo-test--with-script-stub
   (let ((file (eservo-test--temp-file
                "((write \"/tmp/eservo-never.txt\"))\n")))
     (let ((err (should-error (eservo-script-run file))))
       (should (string-match-p "extract" (error-message-string err)))))))

(ert-deftest eservo-script-fill-secret-uses-auth-source ()
  "fill-secret types the auth-source password without echoing it."
  ;; auth-source caches search results (password-data) keyed by the
  ;; whole spec; disable so this test's fresh temp authinfo is read.
  (let* ((auth-source-do-cache nil)
         (authfile (make-temp-file "authinfo"))
         (auth-sources `((:source ,authfile :format t))))
    (with-temp-file authfile
      (insert "machine stub.example login alice password pw-secret\n"))
    (eservo-test--with-script-stub
     (let ((file (eservo-test--temp-file
                  "((fill-secret \"#pass\" \"stub.example\"))\n")))
       (eservo-script-run file)
       (should (member '(fill "#pass" "pw-secret") eservo-test--calls))))))

(ert-deftest eservo-script-session-load-restores-state ()
  "The (session-load SITE) step reuses eservo-session-load."
  (eservo-test--with-script-stub
   (eservo-start 'stub)
   (eservo-session-save "stub.example")
   (let ((file (eservo-test--temp-file
                "((session-load \"stub.example\") (goto \"https://stub.example/chat\"))\n")))
     (eservo-script-run file)
     (should (member '(goto "https://stub.example") eservo-test--calls))
     (should (member '(goto "https://stub.example/chat") eservo-test--calls)))))

(provide 'test-script)
;;; test-script.el ends here
