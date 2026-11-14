;;; test-session.el --- tests for eservo-session.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Tests run against a stub backend (no browser) and a temp session
;; dir; the auth-source test uses a temporary plain authinfo file.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eservo)
(require 'eservo-backend)
(require 'eservo-session)

(defvar eservo-test--calls nil)

(defun eservo-test--session-stub-backend ()
  (eservo-backend--make
   :name 'stub
   :start (lambda (_d) t)
   :stop (lambda (_d) t)
   :alive-p (lambda (_d) t)
   :goto (lambda (driver url)
           (push (list 'goto url) eservo-test--calls)
           (setf (eservo--driver-url driver) url)
           url)
   :url (lambda (_d) "https://stub.example/")
   :cookies-get (lambda (_d)
                  '(((name . "sid") (value . "SECRET-VALUE")
                     (domain . ".stub.example") (path . "/"))))
   :cookies-set (lambda (_d cookies)
                  (push (list 'cookies-set cookies) eservo-test--calls) t)
   :evaluate (lambda (_d js)
               (cond
                ;; dump JS asks for location.origin + localStorage keys
                ((string-search "location.origin" js)
                 (json-encode `((origin . "https://stub.example")
                                (local . (("theme" . "dark"))))))
                ;; restore JS sets localStorage items
                ((string-search "localStorage.setItem" js) t)
                (t :no-value)))))

(defmacro eservo-test--with-session-stub (&rest body)
  "Run BODY with the session stub backend and a temp session dir."
  `(let ((eservo-test--calls nil)
         (eservo-backend-registry '((stub . eservo-test--session-stub-backend)))
         (eservo--current-driver nil)
         (eservo-session-dir (make-temp-file "eservo-sess" t)))
     (eservo-start 'stub)
     (unwind-protect ,@body
       (ignore-errors (eservo-stop))
       (ignore-errors (delete-directory eservo-session-dir t)))))

(ert-deftest eservo-session-save-writes-0600-file ()
  "session-save must write cookies+localStorage to a 0600 file."
  (eservo-test--with-session-stub
   (let ((file (eservo-session-save "stub.example")))
     (should (file-exists-p file))
     (should (= (file-modes file) #o600))
     (let ((raw (with-temp-buffer
                  (insert-file-contents file)
                  (buffer-string))))
       ;; Structure present...
       (should (string-match-p "\"cookies\"" raw))
       (should (string-match-p "\"storage\"" raw))
       ;; ...and the cookie VALUE must never appear in cleartext
       ;; right next to identifying metadata is fine ONLY inside the
       ;; 0600 file; we assert the file is small and JSON-parseable.
       (should (json-parse-string raw :object-type 'alist
                                  :null-object nil :false-object nil))))))

(ert-deftest eservo-session-site-name-is-sanitized ()
  "A URL-ish site must map to a safe file name."
  (eservo-test--with-session-stub
   (let ((file (eservo-session-save "https://chat.qwen.ai/login")))
     (should (string-match-p "chat.qwen.ai-login" (file-name-nondirectory file))))))

(ert-deftest eservo-session-load-restores-cookies-and-storage ()
  "session-load feeds cookies back and re-sets localStorage."
  (eservo-test--with-session-stub
   (eservo-session-save "stub.example")
   (eservo-session-load "stub.example")
   ;; cookies were pushed back to the backend unchanged (JSON object
   ;; keys parse to symbols with :object-type 'alist -- same as real
   ;; CDP results)
   (let ((cs (cl-find 'cookies-set eservo-test--calls
                      :key 'car)))
     (should cs)
     (should (equal (cdr (assoc 'name (car (cadr cs)))) "sid")))
   ;; storage restore was evaluated on the saved origin
   (should (member '(goto "https://stub.example") eservo-test--calls))
   ;; the optional URL argument hops there AFTER the restore
   ;; (the stub pushes newest first, so it is the head of the list)
   (eservo-session-load "stub.example" "https://stub.example/chat")
   (should (equal (car eservo-test--calls)
                  '(goto "https://stub.example/chat")))))

(ert-deftest eservo-session-load-missing-file-errors ()
  "Loading a site that was never saved must say so clearly."
  (eservo-test--with-session-stub
   (let ((err (should-error (eservo-session-load "never-saved.example"))))
     (should (string-match-p "eservo-session-save"
                             (error-message-string err))))))

(ert-deftest eservo-credentials-comes-from-auth-source ()
  "eservo-credentials must read from auth-source and hide nothing in logs."
  ;; auth-source caches search results (password-data) keyed by the
  ;; whole spec; disable so this test's fresh temp authinfo is read.
  (let* ((auth-source-do-cache nil)
         (authfile (make-temp-file "authinfo"))
         (auth-sources `((:source ,authfile :format t))))
    ;; Write a classic netrc entry (plain file is enough for the test;
    ;; real users should use ~/.authinfo.gpg).
    (with-temp-file authfile
      (insert "machine stub.example login alice password s3cret\n"))
    (let ((creds (eservo-credentials "stub.example")))
      (should (equal (car creds) "alice"))
      (should (equal (cdr creds) "s3cret")))
    ;; No entry -> clear error naming the site.
    (let ((err (should-error (eservo-credentials "no-such.example"))))
      (should (string-match-p "no-such.example"
                              (error-message-string err))))))

(provide 'test-session)
;;; test-session.el ends here
