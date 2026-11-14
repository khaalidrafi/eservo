;;; test-servo.el --- ERT tests for eservo-rdp.el and eservo-servo.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Hermetic tests for the Servo backend: no servo binary, no network
;; beyond loopback.  A tiny fake RDP server (pure Elisp network
;; process) speaks the exact packet shapes observed in a real servo
;; devtools session log: length:JSON framing, the root hello with
;; applicationType/traits, a connect echo plus an unsolicited
;; tabListChanged notification (to prove reply matching is race-safe),
;; listTabs with a consoleActor, evaluateJS replies with result /
;; exceptionMessage.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eservo-servo)

;; ------------------------------------------------------------------------
;; Framing unit tests (no process involved)
;; ------------------------------------------------------------------------

(defun eservo-servo-test--conn-with (text)
  "A connection whose accumulation buffer starts with TEXT."
  (let* ((conn (eservo-rdp-conn--make))
         (buf (generate-new-buffer " *eservo-rdp-test*")))
    (with-current-buffer buf (insert text))
    (setf (eservo-rdp--buf conn) buf)
    conn))

(ert-deftest eservo-rdp-parse-one-packet ()
  (let ((conn (eservo-servo-test--conn-with
               (eservo-servo-test--frame '((from . "root") (ok . t))))))
    (eservo-rdp--parse conn)
    (should (equal (eservo-rdp--replies conn)
                   '(((from . "root") (ok . t)))))))

(ert-deftest eservo-rdp-parse-split-packet ()
  "A packet split across chunks parses once the tail arrives."
  (let* ((packet (eservo-servo-test--frame '((from . "root") (n . 1))))
         (conn (eservo-servo-test--conn-with (substring packet 0 9))))
    (eservo-rdp--parse conn)
    (should (null (eservo-rdp--replies conn)))
    (with-current-buffer (eservo-rdp--buf conn)
      (goto-char (point-max)) (insert (substring packet 9)))
    (eservo-rdp--parse conn)
    (should (equal (eservo-rdp--replies conn)
                   '(((from . "root") (n . 1)))))))

(ert-deftest eservo-rdp-parse-two-packets-one-chunk ()
  (let ((conn (eservo-servo-test--conn-with
               (concat (eservo-servo-test--frame '((from . "a")))
                       (eservo-servo-test--frame '((from . "b")))))))
    (eservo-rdp--parse conn)
    ;; push order puts the newest first; both present is what matters.
    (should (= (length (eservo-rdp--replies conn)) 2))))

(ert-deftest eservo-rdp-parse-bad-json-dropped-not-fatal ()
  (let ((conn (eservo-servo-test--conn-with "5:xxxxx")))
    (eservo-rdp--parse conn)
    (should (null (eservo-rdp--replies conn)))
    ;; buffer consumed, further packets still parse
    (with-current-buffer (eservo-rdp--buf conn)
      (goto-char (point-max))
      (insert (eservo-servo-test--frame '((from . "a")))))
    (eservo-rdp--parse conn)
    (should (= (length (eservo-rdp--replies conn)) 1))))

;; ------------------------------------------------------------------------
;; Fake RDP server
;; ------------------------------------------------------------------------

(cl-defstruct (eservo-servo-test--fake
               (:constructor eservo-servo-test--fake-make)
               ;; Accessors eservo-servo-test--server / --port / ...,
               ;; consistent with the file's prefix.
               (:conc-name eservo-servo-test--))
  server proc port clients acc-buf)

(defun eservo-servo-test--frame (obj)
  "Encode OBJ as one RDP packet (length:JSON)."
  (let ((json (json-encode obj)))
    (format "%d:%s" (string-bytes json) json)))

(defun eservo-servo-test--fake-hello (proc)
  "The packet servo pushes on connect (shape from a real session log)."
  (process-send-string
   proc
   (eservo-servo-test--frame
    '((from . "root") (applicationType . "browser")
      (traits . ((sources . nil) (highlightable . t)))))))

(defun eservo-servo-test--fake-start ()
  "Start a fake servo devtools server on a loopback port.
Accepted connections inherit the filter/sentinel below; each gets the
root hello immediately, exactly like servo does."
  (let ((fake (eservo-servo-test--fake-make)))
    (setf (eservo-servo-test--server fake)
          (make-network-process
           :name "eservo-fake-rdp"
           :server t :service 0 :host "127.0.0.1"
           :sentinel
           (lambda (proc event)
             ;; Track clients on accept; also the only cleanup path.
             (when (string-match-p "\\`open" event)
               (push proc (eservo-servo-test--clients fake))
               (eservo-servo-test--fake-hello proc)))
           :filter
           (lambda (_proc data)
             (eservo-servo-test--fake-on-input fake data))))
    (setf (eservo-servo-test--port fake)
          (cadr (process-contact (eservo-servo-test--server fake))))
    fake))

(defun eservo-servo-test--fake-send (fake obj)
  "Push OBJ to every connected client, framed."
  (dolist (proc (eservo-servo-test--clients fake))
    (when (process-live-p proc)
      (process-send-string proc (eservo-servo-test--frame obj)))))

(defun eservo-servo-test--fake-on-input (fake data)
  "Fake server logic: accumulate, parse framed packets, answer them."
  (unless (buffer-live-p (eservo-servo-test--acc-buf fake))
    (setf (eservo-servo-test--acc-buf fake)
          (generate-new-buffer " *eservo-fake-acc*")))
  (with-current-buffer (eservo-servo-test--acc-buf fake)
    (goto-char (point-max))
    (insert data)
    (goto-char (point-min))
    ;; consume every complete packet in the accumulator
    (while (looking-at "\\([0-9]+\\):")
      (let* ((len (string-to-number (match-string 1)))
             (start (1+ (match-end 1)))
             (end (+ start len)))
        (if (< (point-max) end)
            (goto-char (point-max))     ; incomplete: wait for more
          (let* ((body (buffer-substring-no-properties start end))
                 (obj (json-parse-string body :object-type 'alist
                                         :array-type 'list
                                         :null-object nil
                                         :false-object nil)))
            (delete-region (point-min) end)
            (eservo-servo-test--fake-handle fake obj)
            (goto-char (point-min))))))))

(defun eservo-servo-test--fake-handle (fake obj)
  "Answer one parsed client packet OBJ.
Canned evaluateJS responses key off the shape of the JS `text' the
backend ops send, so the op plumbing is tested end to end."
  (let* ((type (cdr (assq 'type obj)))
         (to (cdr (assq 'to obj)))
         (text (cdr (assq 'text obj)))
         (reply-from (lambda (fields)
                       `((from . ,to) ,@fields))))
    (cond
     ((equal type "connect")
      ;; Race test: an unsolicited notification first, then the echo.
      ;; The client must skip both when waiting for listTabs.
      (eservo-servo-test--fake-send
       fake '((from . "root") (type . "tabListChanged")))
      (eservo-servo-test--fake-send
       fake '((from . "root") (type . "connected"))))
     ((equal type "listTabs")
      (eservo-servo-test--fake-send
       fake '((from . "root")
              (selected . 0)
              ;; dotted: the value must be (TAB), not ((TAB)) -- a
              ;; non-dotted (tabs (TAB)) would wrap one array deeper
              (tabs . (((actor . "conn0.target1")
                        (consoleActor . "conn0.console1")
                        (url . "about:blank")
                        (title . "Blank")))))))
     ((equal type "evaluateJS")
      (eservo-servo-test--fake-send
       fake
       (cond
        ;; the test asks the page to throw
        ((and (stringp text) (string-match-p "THROWNOW" text))
         (funcall reply-from '((exceptionMessage . "page boom"))))
        ;; goto's JS assigns location.href
        ((and (stringp text) (string-match-p "location\\.href=" text))
         '((from . "conn0.console1") (result . "navigating")))
        ;; the url op asks exactly this
        ((equal text "location.href")
         '((from . "conn0.console1")
           (result . "https://servo.org/after")))
        ;; fill's JS uses the prototype value setter
        ((and (stringp text)
              (string-match-p "getOwnPropertyDescriptor" text))
         '((from . "conn0.console1") (result . t)))
        ;; snapshot/extract/click/keys/selector-wait JS all query
        ((and (stringp text) (string-match-p "querySelector" text))
         '((from . "conn0.console1") (result . "[1] link \"Home\"")))
        (t
         (funcall reply-from
                  `((result . ,(format "ECHO:%s" (or text ""))))))))))))

(defun eservo-servo-test--fake-stop (fake)
  (ignore-errors (delete-process (eservo-servo-test--server fake)))
  (dolist (proc (eservo-servo-test--clients fake))
    (ignore-errors (delete-process proc)))
  (when (buffer-live-p (eservo-servo-test--acc-buf fake))
    (kill-buffer (eservo-servo-test--acc-buf fake))))

(defun eservo-servo-test--with-fake (body-fn)
  "Run BODY-FN with one argument, the fake server's port."
  (let ((fake (eservo-servo-test--fake-start)))
    (unwind-protect
        (funcall body-fn (eservo-servo-test--port fake))
      (eservo-servo-test--fake-stop fake))))

(defun eservo-servo-test--attached-driver (port)
  "A servo driver ATTACHED to the fake server at PORT."
  (let ((eservo-servo-port port))
    (let ((driver (eservo--driver-make
                   :backend (eservo-servo-make-backend)
                   :name "servo")))
      (eservo-backend-call driver 'start)
      driver)))

;; ------------------------------------------------------------------------
;; Integration tests against the fake
;; ------------------------------------------------------------------------

(ert-deftest eservo-servo-rdp-open-handshake-and-tabs ()
  "open consumes the hello; listTabs survives the connect-echo race."
  (eservo-servo-test--with-fake
   (lambda (port)
     (let* ((conn (eservo-rdp-open "127.0.0.1" port))
            (tabs (eservo-rdp-request conn "root" "listTabs" nil
                                      (lambda (r) (assq 'tabs r)))))
       (should (cdr (assq 'tabs tabs)))
       (should (equal (cdr (assq 'consoleActor
                                 (car (cdr (assq 'tabs tabs)))))
                      "conn0.console1"))
       (eservo-rdp-close conn)))))

(ert-deftest eservo-servo-eval-echoes-js ()
  (eservo-servo-test--with-fake
   (lambda (port)
     (let ((driver (eservo-servo-test--attached-driver port)))
       (unwind-protect
           (progn
             (should (equal (eservo-servo--eval driver "1+1")
                            "ECHO:1+1"))
             (should (equal (eservo-backend-call driver 'evaluate "xyz")
                            "ECHO:xyz")))
         (eservo-backend-call driver 'stop))))))

(ert-deftest eservo-servo-eval-page-exception-signals ()
  (eservo-servo-test--with-fake
   (lambda (port)
     (let ((driver (eservo-servo-test--attached-driver port)))
       (unwind-protect
           (should-error (eservo-servo--eval driver "THROWNOW()"))
         (eservo-backend-call driver 'stop))))))

(ert-deftest eservo-servo-goto-and-url-roundtrip ()
  (eservo-servo-test--with-fake
   (lambda (port)
     (let ((driver (eservo-servo-test--attached-driver port)))
       (unwind-protect
           (progn
             (eservo-backend-call driver 'goto "https://servo.org/")
             (should (equal (eservo--driver-url driver)
                            "https://servo.org/"))
             (should (equal (eservo-backend-call driver 'url)
                            "https://servo.org/after")))
         (eservo-backend-call driver 'stop))))))

(ert-deftest eservo-servo-snapshot-shape ()
  (eservo-servo-test--with-fake
   (lambda (port)
     (let ((driver (eservo-servo-test--attached-driver port)))
       (unwind-protect
           (let ((snap (eservo-backend-call driver 'snapshot)))
             (should (string-prefix-p "URL: " snap))
             (should (string-match-p "\\[1\\] link" snap)))
         (eservo-backend-call driver 'stop))))))

(ert-deftest eservo-servo-fill-ok ()
  (eservo-servo-test--with-fake
   (lambda (port)
     (let ((driver (eservo-servo-test--attached-driver port)))
       (unwind-protect
           (should (eservo-backend-call driver 'fill "#q" "hello"))
         (eservo-backend-call driver 'stop))))))

(ert-deftest eservo-servo-click-missing-element-errors ()
  (eservo-servo-test--with-fake
   (lambda (port)
     (let ((driver (eservo-servo-test--attached-driver port)))
       ;; the fake answers selector JS with an outline string, so the
       ;; click's 'ok' status check fails -> clear, actionable error
       (unwind-protect
           (should-error (eservo-backend-call driver 'click 99))
         (eservo-backend-call driver 'stop))))))

(ert-deftest eservo-servo-unsupported-ops-error-clearly ()
  "Screenshot/cookies are nil ops: dispatch must name them."
  (eservo-servo-test--with-fake
   (lambda (port)
     (let ((driver (eservo-servo-test--attached-driver port)))
       (unwind-protect
           (progn
             (should-error (eservo-backend-call driver 'screenshot
                                                "/tmp/x.png"))
             (should-error (eservo-backend-call driver 'cookies-get)))
         (eservo-backend-call driver 'stop))))))

(ert-deftest eservo-servo-backend-registered ()
  (should (assq 'servo (eservo-backend-registered))))

(provide 'test-servo)
;;; test-servo.el ends here
