;;; test-cdp.el --- tests for eservo-cdp.el (no real browser needed) -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; All tests drive eservo's CDP backend against the fake DevTools
;; endpoint from test-helpers.el (a fake HTTP /json endpoint plus a
;; fake WS JSON-RPC server, both running inside this Emacs process).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'eservo-cdp)
(require 'test-helpers)

(defun eservo-test--make-cdp-driver (fake)
  "Attach a fresh driver to FAKE and return it."
  (let* ((driver (eservo--driver-make
                  :backend (eservo-cdp-make-backend) :name "cdp-test")))
    (let ((eservo-cdp-port (plist-get fake :http)))
      (eservo-cdp--start-op driver))
    driver))

(defun eservo-test--kill-cdp-driver (driver)
  ;; Stop closes the ws; with :proc nil nothing is killed.
  (ignore-errors (eservo-cdp--stop driver)))

(ert-deftest eservo-cdp-attach-picks-page-target ()
  "Attach discovers the page target over HTTP and enables domains."
  (let ((fake (eservo-test--cdp-server))
        (driver (eservo--driver-make
                 :backend (eservo-cdp-make-backend) :name "cdp-test")))
    (unwind-protect
        (progn
          (let ((eservo-cdp-port (plist-get fake :http)))
            (should (eservo-cdp--start-op driver)))
          (should (eservo-cdp--alive-p driver))
          (should (equal (eservo--driver-url driver) "about:blank"))
          ;; Page.enable and Network.enable must have been sent.
          (should (member "Page.enable" (plist-get fake :requests)))
          (should (member "Network.enable" (plist-get fake :requests))))
      (eservo-test--kill-cdp-driver driver))))

(ert-deftest eservo-cdp-goto-navigates ()
  "goto issues Page.navigate and records the URL."
  (let ((fake (eservo-test--cdp-server)))
    (let ((driver (eservo-test--make-cdp-driver fake)))
      (unwind-protect
          (progn
            (eservo-cdp--goto driver "https://example.com/")
            (should (equal (eservo--driver-url driver) "https://example.com/"))
            (should (member "Page.navigate" (plist-get fake :requests))))
        (eservo-test--kill-cdp-driver driver)))))

(ert-deftest eservo-cdp-evaluate-returns-value ()
  "Runtime.evaluate results come back via returnByValue."
  (let* ((replies
          '(("Runtime.evaluate" .
             ((result . ((result . ((type . "string") (value . "hello-from-js")))))))))
         (fake (eservo-test--cdp-server replies)))
    (let ((driver (eservo-test--make-cdp-driver fake)))
      (unwind-protect
          (should (equal (eservo-cdp--evaluate driver "1+1")
                         "hello-from-js"))
        (eservo-test--kill-cdp-driver driver)))))

(ert-deftest eservo-cdp-evaluate-exception-errors ()
  "JS exceptions surface as Elisp errors with the CDP text."
  (let* ((replies
          '(("Runtime.evaluate" .
             ((result . ((exceptionDetails . ((text . "SyntaxError: bad")))))))))
         (fake (eservo-test--cdp-server replies)))
    (let ((driver (eservo-test--make-cdp-driver fake)))
      (unwind-protect
          (let ((err (should-error (eservo-cdp--evaluate driver "nope"))))
            (should (string-match-p "SyntaxError"
                                    (error-message-string err))))
        (eservo-test--kill-cdp-driver driver)))))

(ert-deftest eservo-cdp-snapshot-returns-outline ()
  "snapshot returns URL header plus the outline produced by the JS."
  (let* ((replies
          '(("Runtime.evaluate" .
             ((result . ((result . ((type . "string")
                                    (value . "[1] button \"Send\"")))))))))
         (fake (eservo-test--cdp-server replies)))
    (let ((driver (eservo-test--make-cdp-driver fake)))
      (unwind-protect
          (let ((snap (eservo-cdp--snapshot driver)))
            (should (string-match-p "URL: about:blank" snap))
            (should (string-match-p "\\[1\\] button" snap)))
        (eservo-test--kill-cdp-driver driver)))))

(ert-deftest eservo-cdp-fill-sends-escaped-js ()
  "fill embeds the selector and text as JSON literals (quote-safe)."
  (let ((fake (eservo-test--cdp-server
               '(("Runtime.evaluate" .
                  ((result . ((result . ((type . "boolean") (value . t)))))))))))
    (let ((driver (eservo-test--make-cdp-driver fake)))
      (unwind-protect
          (progn
            (eservo-cdp--fill driver "textarea.msg" "say \"hi\"")
            ;; The recorded expression must contain the JSON-escaped
            ;; selector and text (so quotes in user input cannot break
            ;; out of the JS string).
            (let* ((call (cl-find "Runtime.evaluate"
                                  (plist-get fake :calls)
                                  :key 'car :test 'string=))
                   (expr (cdr (assoc 'expression (cdr call)))))
              (should (string-match-p "\"textarea.msg\"" expr))
              (should (string-match-p "say \\\\\"hi\\\\\"" expr))))
        (eservo-test--kill-cdp-driver driver)))))

(ert-deftest eservo-cdp-fill-missing-element-errors ()
  "fill must error when the selector matches nothing (JS false)."
  (let ((fake (eservo-test--cdp-server
               `(("Runtime.evaluate" .
                  ((result . ((result . ((type . "boolean")
                                         (value . ,json-false)))))))))))
    (let ((driver (eservo-test--make-cdp-driver fake)))
      (unwind-protect
          (should-error (eservo-cdp--fill driver "nothing" "x"))
        (eservo-test--kill-cdp-driver driver)))))

(ert-deftest eservo-cdp-click-ref-and-miss ()
  "click resolves esvref targets; a miss is a clear error."
  (let ((fake-ok (eservo-test--cdp-server
                  '(("Runtime.evaluate" .
                     ((result . ((result . ((type . "string") (value . "ok"))))))))))
        (fake-miss (eservo-test--cdp-server
                    '(("Runtime.evaluate" .
                       ((result . ((result . ((type . "string")
                                              (value . "no-element")))))))))))
    (let ((driver (eservo-test--make-cdp-driver fake-ok)))
      (unwind-protect
          (progn
            (should (eservo-cdp--click driver 3))
            ;; The generated selector must target the esvref attribute.
            (let* ((call (car (plist-get fake-ok :calls)))
                   (expr (cdr (assoc 'expression (cdr call)))))
              (should (string-match-p "esvref" expr))))
        (eservo-test--kill-cdp-driver driver)))
    (let ((driver (eservo-test--make-cdp-driver fake-miss)))
      (unwind-protect
          (should-error (eservo-cdp--click driver 9))
        (eservo-test--kill-cdp-driver driver)))))

(ert-deftest eservo-cdp-keys-ret-dispatches-key-events ()
  "RET maps to Input.dispatchKeyEvent keyDown/keyUp with code Enter."
  (let ((fake (eservo-test--cdp-server)))
    (let ((driver (eservo-test--make-cdp-driver fake)))
      (unwind-protect
          (progn
            (eservo-cdp--keys driver "RET")
            ;; two events for one RET
            (should (= (cl-count "Input.dispatchKeyEvent"
                                 (plist-get fake :requests)
                                 :test 'string=)
                       2))
            (let ((call (cl-find "Input.dispatchKeyEvent"
                                 (plist-get fake :calls)
                                 :key 'car :test 'string=)))
              (should (equal (cdr (assoc 'key (cdr call))) "Enter"))))
        (eservo-test--kill-cdp-driver driver)))))

(ert-deftest eservo-cdp-keys-text-uses-insert-text ()
  "Plain text goes through Input.insertText."
  (let ((fake (eservo-test--cdp-server)))
    (let ((driver (eservo-test--make-cdp-driver fake)))
      (unwind-protect
          (progn
            (eservo-cdp--keys driver "hello world")
            (should (= (cl-count "Input.insertText"
                                 (plist-get fake :requests)
                                 :test 'string=)
                       2)))  ; "hello" and "world"
        (eservo-test--kill-cdp-driver driver)))))

(ert-deftest eservo-cdp-screenshot-writes-png ()
  "screenshot decodes base64 and writes the bytes to FILE."
  (let* ((payload "PNGDATA")
         (b64 (base64-encode-string payload t))
         (fake (eservo-test--cdp-server
                `(("Page.captureScreenshot" . ((data . ,b64))))))
         (driver (eservo-test--make-cdp-driver fake))
         (out (make-temp-file "eservo-out" nil ".png")))
    (unwind-protect
        (progn
          (eservo-cdp--screenshot driver out)
          (with-temp-buffer
            (insert-file-contents out)
            (should (string= (buffer-string) payload))))
      (eservo-test--kill-cdp-driver driver))))

(ert-deftest eservo-cdp-cookies-roundtrip ()
  "cookies-get returns the cookie list; cookies-set re-sends each."
  (let* ((cookies '(((name . "sid") (value . "abc")
                     (domain . ".example.com") (path . "/"))))
         (fake (eservo-test--cdp-server
                `(("Network.getAllCookies" . ((cookies . ,cookies)))))))
    (let ((driver (eservo-test--make-cdp-driver fake)))
      (unwind-protect
          (progn
            (should (equal (eservo-cdp--cookies-get driver) cookies))
            (eservo-cdp--cookies-set driver cookies)
            ;; Network.setCookie sent once for our single cookie, with
            ;; the cookie fields passed through unchanged.
            (should (= (cl-count "Network.setCookie"
                                 (plist-get fake :requests)
                                 :test 'string=)
                       1))
            (let ((call (cl-find "Network.setCookie"
                                 (plist-get fake :calls)
                                 :key 'car :test 'string=)))
              (should (equal (cdr call) (car cookies)))))
        (eservo-test--kill-cdp-driver driver)))))

(ert-deftest eservo-cdp-no-program-errors-cleanly ()
  "Launching with no findable browser must produce a helpful error."
  (let ((eservo-cdp-program '("eservo-definitely-not-a-browser"))
        (eservo-cdp-port nil))
    (let ((err (should-error (eservo-cdp--find-program))))
      (should (string-match-p "PATH" (error-message-string err))))))

(provide 'test-cdp)
;;; test-cdp.el ends here
