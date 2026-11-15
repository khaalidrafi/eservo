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
;;
;; The Android on-device start lanes are covered the same way: adb
;; and the patched-Emacs `android-start-activity' primitive are
;; stubbed (the primitive with an explicit fbind/fmakunbound dance,
;; because `cl-letf' cannot even SAVE a void function cell), and the
;; attach lands on the fake RDP server like every other test.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eservo-servo)
;; The android start lanes attach through `eservo-start', which also
;; owns `eservo--current-driver' (a defvar: binding it dynamically in
;; the tests below only works once eservo.el is loaded).
(require 'eservo)

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

;; ------------------------------------------------------------------------
;; Android on-device start lanes (offline: adb, the patched-Emacs
;; primitive and the app itself are all stubbed; the attach goes to
;; the same fake RDP server as the rest of this suite)
;; ------------------------------------------------------------------------

(defun eservo-servo-test--with-primitive (stub body-fn)
  "Call BODY-FN with `android-start-activity' in a controlled state.
STUB non-nil fbinds the primitive to it (the patched-Emacs lane);
STUB nil fmakunbounds it (stock Emacs has no such primitive).  The
previous state of the function cell -- usually void -- is restored
afterwards.  Plain `cl-letf' cannot do this: its place getter for
`(symbol-function X)' signals void-function when X is void, so the
save/restore dance lives here."
  (let ((was (fboundp 'android-start-activity))
        (old (and (fboundp 'android-start-activity)
                  (symbol-function 'android-start-activity))))
    (unwind-protect
        (progn
          (if stub
              (defalias 'android-start-activity stub)
            (fmakunbound 'android-start-activity))
          (funcall body-fn))
      (if was
          (defalias 'android-start-activity old)
        (fmakunbound 'android-start-activity)))))

(defun eservo-servo-test--with-adb-stub (body-fn)
  "Call BODY-FN with adb on PATH and `call-process' faked.
Return the recorded call-process argv lists (the part after PROGRAM
INFILE BUFFER DISPLAY), newest first; every call exits 0.  The argv
is captured as a LIST (not one shell string) so a wrongly-spread
argument -- the repo's `apply' bug class -- cannot pass unnoticed."
  (let (calls)
    (cl-letf (((symbol-function 'executable-find)
               ;; `executable-find' takes (NAME &optional REMOTE).
               (lambda (name &optional _remote)
                 (when (string= name "adb") "/fake/bin/adb")))
              ((symbol-function 'call-process)
               (lambda (_program _infile _buffer _display &rest args)
                 (push args calls)
                 0)))
      (funcall body-fn))
    calls))

(ert-deftest eservo-servo-android-start-emacs-lane ()
  "Seam gets PKG/ACTIVITY + the servoargs extra; attach is loopback."
  (eservo-servo-test--with-fake
   (lambda (port)
     (let ((eservo--current-driver nil)
           (eservo-servo-port port)
           ;; a non-loopback host must be ignored: the on-device
           ;; attach is always 127.0.0.1
           (eservo-servo-host "192.0.2.1")
           (started nil))
       (eservo-servo-test--with-primitive
        (lambda (&rest _) t)
        (lambda ()
          (let ((eservo-servo-android-start-function
                 (lambda (activity extras)
                   (push (cons activity extras) started))))
            (unwind-protect
                (progn
                  (eservo-servo-android-start)
                  (should
                   (equal started
                          (list
                           (cons "org.servo.servoshell/org.servo.servoshell.MainActivity"
                                 `(("servoargs" . ,(format "--devtools=%d" port)))))))
                  (should (and eservo--current-driver
                               (eservo-backend-call eservo--current-driver
                                                    'alive-p))))
              (eservo-stop)))))))))

(ert-deftest eservo-servo-android-adb-start-via-adb-am-command ()
  "The adb lane runs am start -n PKG/ACTIVITY with --es extras."
  (let ((calls
         (eservo-servo-test--with-adb-stub
          (lambda ()
            (should (eq (eservo-servo-android--start-via-adb
                         "org.servo.servoshell/org.servo.servoshell.MainActivity"
                         '(("servoargs" . "--devtools=6080")))
                        t))))))
    (should (equal calls
                   (list (list "shell" "am" "start" "-n"
                               "org.servo.servoshell/org.servo.servoshell.MainActivity"
                               "--es" "servoargs" "--devtools=6080"))))))

(ert-deftest eservo-servo-android-start-adb-lane-when-no-primitive ()
  "Stock Emacs (no primitive) + adb on PATH: the adb lane starts the app."
  (eservo-servo-test--with-fake
   (lambda (port)
     (let ((eservo--current-driver nil)
           (eservo-servo-port port))
       (eservo-servo-test--with-primitive
        nil
        (lambda ()
          (let ((calls
                 (eservo-servo-test--with-adb-stub
                  (lambda ()
                    (unwind-protect
                        (progn
                          (eservo-servo-android-start)
                          (should (and eservo--current-driver
                                       (eservo-backend-call
                                        eservo--current-driver 'alive-p))))
                      (eservo-stop))))))
            (should (equal calls
                           (list (list "shell" "am" "start" "-n"
                                       "org.servo.servoshell/org.servo.servoshell.MainActivity"
                                       "--es" "servoargs"
                                       (format "--devtools=%d" port))))))))))))

(ert-deftest eservo-servo-android-start-prefix-arg-prefers-adb ()
  "C-u picks the adb lane even when the patched primitive exists."
  (eservo-servo-test--with-fake
   (lambda (port)
     (let ((eservo--current-driver nil)
           (eservo-servo-port port)
           (primitive-calls 0))
       (eservo-servo-test--with-primitive
        (lambda (_activity &optional _extras)
          (cl-incf primitive-calls)
          t)
        (lambda ()
          (let ((calls
                 (eservo-servo-test--with-adb-stub
                  (lambda ()
                    (unwind-protect
                        (eservo-servo-android-start '(4))
                      (eservo-stop))))))
            (should (equal primitive-calls 0))
            (should (equal calls
                           (list (list "shell" "am" "start" "-n"
                                       "org.servo.servoshell/org.servo.servoshell.MainActivity"
                                       "--es" "servoargs"
                                       (format "--devtools=%d" port))))))))))))

(ert-deftest eservo-servo-android-start-no-lane-errors-clearly ()
  "No primitive and no adb: a clear error naming the spec and the lane."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_name &optional _remote) nil)))
    (eservo-servo-test--with-primitive
     nil
     (lambda ()
       (let ((err (should-error (eservo-servo-android-start))))
         (should (string-match-p "android-start-activity"
                                 (error-message-string err)))
         (should (string-match-p "adb" (error-message-string err))))))))


;; ----- the plain `am' lane (Android without adb) -----------------------

(defun eservo-servo-test--with-am-stub (body-fn)
  "Call BODY-FN with termux-am/adb on PATH and `call-process' faked.
Return the recorded (PROGRAM . ARGS) calls, newest first; every call
exits 0.  `/system/bin/am' is pointed at a fake executable file so
the am resolution is exercised for real."
  (let (calls
        (fake-am (make-temp-file "eservo-fake-am")))
    ;; make-temp-file creates the file; give it an empty content -- only
    ;; its existence+executability matters to the resolver.
    (let (process-file-side-effects)
      (cl-letf (((symbol-function 'executable-find)
                 ;; `executable-find' takes (NAME &optional REMOTE).
                 (lambda (name &optional _remote)
                   (cond ((string= name "termux-am") "/fake/bin/termux-am")
                         ((string= name "adb") "/fake/bin/adb")
                         (t nil))))
                ((symbol-function 'file-executable-p)
                 (lambda (file &optional _group)
                   (or (string= file "/system/bin/am")
                       (file-executable-p file))))
                ((symbol-function 'call-process)
                 (lambda (program _infile _buffer _display &rest args)
                   (push (cons program args) calls)
                   0)))
        (funcall body-fn)))
    calls))

(ert-deftest eservo-servo-android-am-start-via-am-command ()
  "The am lane runs `am start -n PKG/ACTIVITY' with --es extras."
  (let (calls)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (name &optional _remote)
                 (when (string= name "termux-am") "/fake/bin/termux-am")))
              ((symbol-function 'file-executable-p)
               (lambda (file &optional _group)
                 (not (string= file "/system/bin/am"))))
              ((symbol-function 'call-process)
               (lambda (program _infile _buffer _display &rest args)
                 (push (cons program args) calls)
                 0)))
      (should (eq (eservo-servo-android--start-via-am
                   "org.servo.servoshell/org.servo.servoshell.MainActivity"
                   '(("servoargs" . "--devtools=6080")))
                  t)))
    (should (equal (car (car calls)) "/fake/bin/termux-am"))
    (should (equal (cdr (car calls))
                   (list "start" "-n"
                         "org.servo.servoshell/org.servo.servoshell.MainActivity"
                         "--es" "servoargs" "--devtools=6080")))))

(ert-deftest eservo-servo-android-am-start-errors-without-am ()
  "No termux-am and no /system/bin/am: a clear error naming the lanes."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_name &optional _remote) nil))
            ((symbol-function 'file-executable-p)
             (lambda (file &optional _group)
               (not (string= file "/system/bin/am")))))
    (let ((err (should-error (eservo-servo-android--start-via-am
                              "org.servo.servoshell/org.servo.servoshell.MainActivity"
                              nil))))
      (should (string-match-p "termux-am"
                              (error-message-string err)))
      (should (string-match-p "adb"
                              (error-message-string err))))))

(ert-deftest eservo-servo-android-start-am-lane-when-no-primitive ()
  "Stock Emacs (no primitive) + am usable: the am lane starts the app."
  (eservo-servo-test--with-fake
   (lambda (port)
     (let ((eservo--current-driver nil)
           (eservo-servo-port port))
       (eservo-servo-test--with-primitive
        nil
        (lambda ()
          (let ((calls
                 (eservo-servo-test--with-am-stub
                  (lambda ()
                    (unwind-protect
                        (progn
                          (eservo-servo-android-start)
                          (should (and eservo--current-driver
                                       (eservo-backend-call eservo--current-driver
                                                            'alive-p))))
                      (eservo-stop))))))
            ;; termux-am was used, NOT adb: no "shell" prefix anywhere.
            (should (equal (car (car calls)) "/fake/bin/termux-am"))
            (should (equal (cdr (car calls))
                           (list "start" "-n"
                                 "org.servo.servoshell/org.servo.servoshell.MainActivity"
                                 "--es" "servoargs"
                                 (format "--devtools=%d" port)))))))))))

(provide 'test-servo)
;;; test-servo.el ends here
