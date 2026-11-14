;;; test-adb.el --- tests for eservo-adb.el (no device, no adb) -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; All adb interactions are faked by cl-letf-ing `eservo-adb--run' and
;; `eservo-adb--run-raw', so no `adb' binary and no Android device are
;; needed here.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eservo)
(require 'eservo-backend)
(require 'eservo-adb)

;; A tiny, realistic chunk of uiautomator XML (machine-generated, one
;; node per element).
(defconst eservo-test--uidump
  "<?xml version='1.0'?><hierarchy><node index='0' text='' class='android.widget.FrameLayout' clickable='false' bounds='[0,0][1080,2400]'/>
<node index='1' text='Search or type URL' class='android.widget.EditText' clickable='true' bounds='[84,120][700,190]'/>
<node index='2' text='' content-desc='Send' class='android.widget.Button' clickable='true' bounds='[760,120][1020,190]'/>
</hierarchy>")

(defmacro eservo-test--with-adb-fake (&rest body)
  "Fake adb: executables exist, get-state says device, dump returns XML.
Recorded commands land in `eservo-test--calls' (newest first)."
  `(let ((eservo-test--calls nil)
         (eservo--current-driver nil))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (_p &optional _remote) "/fake/adb"))
               ((symbol-function 'eservo-adb--run)
                (lambda (&rest args)
                  (let ((cmd (mapconcat #'identity (remq nil args) " ")))
                    (push (cons 'run cmd) eservo-test--calls)
                    (cond
                     ((string-prefix-p "get-state" cmd) "device")
                     ((string-prefix-p "shell uiautomator dump" cmd) "")
                     ((string-prefix-p "shell cat" cmd) eservo-test--uidump)
                     (t (concat "ok: " cmd))))))
               ((symbol-function 'eservo-adb--run-raw)
                (lambda (&rest args)
                  (push (cons 'raw (mapconcat #'identity args " "))
                        eservo-test--calls)
                  "FAKEPNGBYTES")))
       ,@body)))

(ert-deftest eservo-adb-missing-program-errors-cleanly ()
  "Without adb in PATH, start must fail with an install hint."
  (cl-letf (((symbol-function 'executable-find) (lambda (_p &optional _r) nil)))
    (let ((err (should-error (eservo-adb--check-program))))
      (should (string-match-p "PATH" (error-message-string err)))
      (should (string-match-p "adb" (error-message-string err))))))

(ert-deftest eservo-adb-start-and-alive ()
  (eservo-test--with-adb-fake
   (let ((driver (eservo--driver-make
                  :backend (eservo-adb-make-backend) :name "adb-test")))
     (should (eservo-adb--start-op driver))
     (should (eservo-adb--alive-p driver)))))

(ert-deftest eservo-adb-goto-opens-browser-with-url ()
  (eservo-test--with-adb-fake
   (let ((driver (eservo--driver-make
                  :backend (eservo-adb-make-backend) :name "adb-test")))
     (eservo-adb--start-op driver)
     (eservo-adb--goto driver "https://example.org")
     (should (member
              '(run . "shell am start -a android.intent.action.VIEW -d https://example.org com.android.chrome")
              eservo-test--calls))
     (should (equal (eservo-adb--url driver) "https://example.org")))))

(ert-deftest eservo-adb-snapshot-lists-refs-and-click-taps-bounds ()
  "snapshot builds [N] refs; click REF taps the element's center."
  (eservo-test--with-adb-fake
   (let ((driver (eservo--driver-make
                  :backend (eservo-adb-make-backend) :name "adb-test")))
     (eservo-adb--start-op driver)
     (let ((snap (eservo-adb--snapshot driver)))
       ;; the EditText by its text and the Send button by its desc
       (should (string-match-p "\\[1\\].*Search or type URL" snap))
       (should (string-match-p "\\[2\\].*Send" snap))
       ;; click goes through backend dispatch (the adb backend maps
       ;; the click op onto `eservo-adb--tap')
       (eservo-backend-call driver 'click 2)
       ;; center of [760,120][1020,190] = (890,155)
       (should (member '(run . "shell input tap 890 155")
                       eservo-test--calls))))))

(ert-deftest eservo-adb-fill-taps-and-types ()
  "fill by text= taps the field and types via `input text'."
  (eservo-test--with-adb-fake
   (let ((driver (eservo--driver-make
                  :backend (eservo-adb-make-backend) :name "adb-test")))
     (eservo-adb--start-op driver)
     (eservo-adb--snapshot driver)
     (eservo-adb--fill driver "text=Search or type URL" "hello world")
     (should (member '(run . "shell input tap 392 155")
                     eservo-test--calls)) ; center of [84,120][700,190]
     (should (member '(run . "shell input text hello%sworld")
                     eservo-test--calls))))
  ;; plain CSS selectors must fail clearly on Android
  (eservo-test--with-adb-fake
   (let ((driver (eservo--driver-make
                  :backend (eservo-adb-make-backend) :name "adb-test")))
     (eservo-adb--start-op driver)
     (let ((err (should-error (eservo-adb--fill driver "textarea" "x"))))
       (should (string-match-p "text=" (error-message-string err)))))))

(ert-deftest eservo-adb-keys-map-to-keyevents ()
  (eservo-test--with-adb-fake
   (let ((driver (eservo--driver-make
                  :backend (eservo-adb-make-backend) :name "adb-test")))
     (eservo-adb--start-op driver)
     (eservo-adb--keys driver "RET")
     (should (member '(run . "shell input keyevent 66") eservo-test--calls))
     (eservo-adb--keys driver "TAB DEL SPC")
     (should (member '(run . "shell input keyevent 61") eservo-test--calls))
     (should (member '(run . "shell input keyevent 67") eservo-test--calls))
     (should (member '(run . "shell input keyevent 62") eservo-test--calls))
     (eservo-adb--keys driver "hi")
     (should (member '(run . "shell input text hi") eservo-test--calls)))))

(ert-deftest eservo-adb-unsupported-ops-fail-clearly ()
  "CSS waits/extract/JS do not exist on the adb backend."
  (eservo-test--with-adb-fake
   (let ((driver (eservo--driver-make
                  :backend (eservo-adb-make-backend) :name "adb-test")))
     (eservo-adb--start-op driver)
     (should-error (eservo-adb--wait driver "div.answer"))
     (should-error (eservo-backend-call driver 'extract ".x"))
     (should-error (eservo-backend-call driver 'evaluate "1+1")))))

(ert-deftest eservo-adb-screenshot-writes-raw-bytes ()
  (eservo-test--with-adb-fake
   (let* ((driver (eservo--driver-make
                   :backend (eservo-adb-make-backend) :name "adb-test"))
          (out (make-temp-file "eservo-adb" nil ".png")))
     (unwind-protect
         (progn
           (eservo-adb--start-op driver)
           (should (equal (eservo-adb--screenshot driver out) out))
           (with-temp-buffer
             (insert-file-contents out)
             (should (string= (buffer-string) "FAKEPNGBYTES"))))
       (ignore-errors (delete-file out))))))

(provide 'test-adb)
;;; test-adb.el ends here
