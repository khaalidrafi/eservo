;;; eservo-adb.el --- Android (adb) backend for eservo, best effort -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of eservo.  See the header of eservo.el for details.

;;; Commentary:

;; Best-effort v0.1 Android backend: drive the device browser with
;; `adb shell'.  Works on Linux desktop and Termux (adb from
;; `pkg install android-tools'); no GUI libs involved, so it also
;; works from `emacs -nw'.
;;
;; WHAT WORKS: open URLs in the browser, a uiautomator-based snapshot
;; with [N] refs, tap by ref or "text=...", type text, key events,
;; screencap screenshots.
;;
;; LIMITS (documented on purpose -- this is a UI automator, not a
;; DOM driver):
;; - There is no DOM, so `extract', `evaluate', cookie ops and CSS
;;   selector waits are UNSUPPORTED (clear errors via the dispatch
;;   layer).  Sessions (cookies/localStorage) are inside the Android
;;   browser itself, so `eservo-session-*' ops are unsupported too.
;; - `fill' only accepts "text=..." selectors (tap the field first,
;;   then `input text'); typing is native IME-level input, therefore
;;   NOT React-safe in webviews, just a plain keyboard simulation.
;; - `input text' cannot type quote characters reliably; spaces are
;;   sent as %s (the Android convention).
;; - The snapshot only shows what uiautomator sees (accessibility
;;   tree); Chromium's web content often appears as one big WebView
;;   node -- use `chrome://' pages or native UI, or drive real sites
;;   with the cdp backend instead.

;;; Code:

(require 'cl-lib)
(require 'eservo-backend)

(defgroup eservo-adb nil
  "Android adb backend for eservo."
  :group 'eservo)

(defcustom eservo-adb-program "adb"
  "adb executable, resolved from PATH (Termux: android-tools pkg)."
  :group 'eservo-adb
  :type 'string)

(defcustom eservo-adb-args nil
  "Extra adb arguments, e.g. (\"-s\" \"SERIAL\") to pick a device."
  :group 'eservo-adb
  :type '(repeat string))

(defcustom eservo-adb-browser-package "com.android.chrome"
  "Android package of the browser `eservo-goto' opens URLs in."
  :group 'eservo-adb
  :type 'string)

;; Key token -> Android KEYCODE (views/View.java).
(defconst eservo-adb--keycodes
  '(("RET" . 66) ("ENTER" . 66) ("TAB" . 61) ("DEL" . 67)
    ("BACKSPACE" . 67) ("ESC" . 111) ("ESCAPE" . 111) ("SPC" . 62)
    ("UP" . 19) ("DOWN" . 20) ("LEFT" . 21) ("RIGHT" . 22)
    ("PGUP" . 92) ("PGDN" . 93) ("HOME" . 122) ("END" . 123)
    ("DELETE" . 67)))

;; ----- process plumbing -----------------------------------------------

(defun eservo-adb--check-program ()
  "Resolve adb from PATH or fail with a Termux-aware hint."
  (or (executable-find eservo-adb-program)
      (error "eservo-adb: `%s' not found in PATH (Termux: pkg install android-tools; desktop: install adb)"
             eservo-adb-program)))

(defun eservo-adb--run (&rest args)
  "Run adb with ARGS; return trimmed stdout, or signal a clear error."
  (let ((prog (eservo-adb--check-program))
        (full (append eservo-adb-args args))
        (buf (generate-new-buffer " *eservo-adb*")))
    (unwind-protect
        (progn
          (unless (zerop (apply #'call-process prog nil buf nil full))
            (error "eservo-adb: `%s' failed: %s"
                   (mapconcat #'identity full " ")
                   (string-trim (buffer-string))))
          (string-trim (buffer-string)))
      (kill-buffer buf))))

(defun eservo-adb--run-raw (&rest args)
  "Like `eservo-adb--run' but return binary stdout (for screencap)."
  (let ((prog (eservo-adb--check-program))
        (full (append eservo-adb-args args))
        (buf (generate-new-buffer " *eservo-adb*"))
        (coding-system-for-read 'no-conversion))
    (unwind-protect
        (progn
          (unless (zerop (apply #'call-process prog nil buf nil full))
            (error "eservo-adb: `%s' failed" (mapconcat #'identity full " ")))
          (buffer-string))
      (kill-buffer buf))))

;; ----- uiautomator snapshot -------------------------------------------

(defun eservo-adb--xml-attr (tag name)
  "Extract attribute NAME from a uiautomator <node TAG> string.
Accepts both single- and double-quoted attributes (real uiautomator
emits double quotes; single quotes keep test fixtures flexible)."
  (when (string-match (format "%s=[\"']\\(.*?\\)[\"']" (regexp-quote name)) tag)
    (match-string 1 tag)))

(defun eservo-adb--xml-attr-nonempty (tag name)
  "Attribute NAME of TAG, or nil when missing or empty.
uiautomator writes an empty text attribute on most nodes; treating
that empty string as present would shadow the content-desc
fallback in callers (empty strings are truthy in Lisp)."
  (let ((v (eservo-adb--xml-attr tag name)))
    (and v (not (string= v "")) v)))

(defun eservo-adb--parse-bounds (s)
  "Parse \"[x1,y1][x2,y2]\" into (X1 Y1 X2 Y2), or nil."
  (when (and s
             (string-match
              "\\[\\([0-9]+\\),\\([0-9]+\\)\\]\\[\\([0-9]+\\),\\([0-9]+\\)\\]" s))
    (mapcar #'string-to-number
            (list (match-string 1 s) (match-string 2 s)
                  (match-string 3 s) (match-string 4 s)))))

(defun eservo-adb--parse-nodes (xml)
  "Return interesting uiautomator nodes from XML as alists.
A node is interesting when it is clickable or carries visible text."
  (let ((nodes '()) (pos 0))
    (while (string-match "<node[^>]*>" xml pos)
      ;; Capture the tag and its end position BEFORE any helper runs:
      ;; the helpers below call `string-match' themselves and clobber
      ;; the match data -- reading `match-end' afterwards would freeze
      ;; POS at the same small offset forever (infinite loop).
      (let ((tag (match-string 0 xml))
            (end (match-end 0)))
        (let* ((text (or (eservo-adb--xml-attr-nonempty tag "text")
                         (eservo-adb--xml-attr-nonempty tag "content-desc")))
               (clickable (string= "true"
                                   (or (eservo-adb--xml-attr tag "clickable")
                                       "")))
               (bounds (eservo-adb--parse-bounds
                        (eservo-adb--xml-attr tag "bounds"))))
          ;; Interesting = clickable or has visible text.  TEXT is nil
          ;; when both text and content-desc are empty/absent; guard
          ;; explicitly, because (string= nil "") would compare nil's
          ;; SYMBOL NAME ("nil") and wrongly count it as text.
          (when (and (or clickable
                         (and text (not (string= text ""))))
                     bounds)
            (push (list (cons 'text text) (cons 'clickable clickable)
                        (cons 'bounds bounds))
                  nodes)))
        (setq pos end)))
    (nreverse nodes)))

(defun eservo-adb--center (bounds)
  "Center point (X Y) of a (X1 Y1 X2 Y2) BOUNDS list."
  (list (/ (+ (nth 0 bounds) (nth 2 bounds)) 2)
        (/ (+ (nth 1 bounds) (nth 3 bounds)) 2)))

(defun eservo-adb--snapshot (driver)
  "Dump the accessibility tree and build a [N] ref outline.
Refs are remembered in the driver for `eservo-adb--click'."
  (eservo-adb--run "shell" "uiautomator" "dump" "/sdcard/eservo-uidump.xml")
  (let* ((xml (eservo-adb--run "shell" "cat" "/sdcard/eservo-uidump.xml"))
         (nodes (eservo-adb--parse-nodes xml))
         (out '())
         (refs '()))
    (cl-loop for node in nodes
             for i from 1
             do (let ((text (cdr (assoc 'text node)))
                      (bounds (cdr (assoc 'bounds node))))
                  (push (list i bounds text) refs)
                  (push (format "[%d] %s %S @%S" i
                                (if (cdr (assoc 'clickable node))
                                    "clickable" "text")
                                (or text "") (eservo-adb--center bounds))
                        out)))
    (setf (eservo--driver-opts driver)
          (plist-put (eservo--driver-opts driver)
                     :refs (nreverse refs)))
    (format "URL: %s\n%s"
            (or (eservo--driver-url driver) "?")
            (if out (mapconcat #'identity (nreverse out) "\n")
              " (no interesting elements)"))))

;; ----- ops ------------------------------------------------------------

(defun eservo-adb--tap (driver ref)
  "Tap REF: a snapshot index, \"text=...\", or a (X Y) coordinate pair."
  (cond
   ((numberp ref)
    (let* ((entry (assq ref (plist-get (eservo--driver-opts driver) :refs)))
           (bounds (cadr entry)))
      (unless entry
        (error "eservo-adb: no such snapshot ref %S (run eservo-snapshot)" ref))
      ;; recurse with the center as ONE (X Y) list argument
      (eservo-adb--tap driver (eservo-adb--center bounds))))
   ((and (stringp ref) (string-prefix-p "text=" ref))
    ;; find the element by text and tap its center
    (let* ((want (substring ref 5))
           (entry (cl-find want
                           (plist-get (eservo--driver-opts driver) :refs)
                           :key (lambda (e) (nth 2 e)) :test 'string=)))
      (unless entry
        (error "eservo-adb: no element with text %S (run eservo-snapshot)" want))
      (eservo-adb--tap driver (eservo-adb--center (cadr entry)))))
   ;; raw coordinates: useful because uiautomator often cannot see
   ;; inside Chromium's WebView (see LIMITS in the commentary).
   ((and (listp ref) (= (length ref) 2)
         (numberp (car ref)) (numberp (cadr ref)))
    (eservo-adb--run "shell" "input" "tap"
                     (number-to-string (car ref))
                     (number-to-string (cadr ref))))
   (t (error "eservo-adb: bad tap target %S" ref))))

(defun eservo-adb--start-op (driver)
  "Verify a device is attached; nothing persistent to launch."
  (unless (string= (eservo-adb--run "get-state") "device")
    (error "eservo-adb: no device attached (adb get-state failed)"))
  (setf (eservo--driver-opts driver) (list :url "about:blank" :refs nil))
  t)

(defun eservo-adb--stop (driver)
  ;; There is no eservo-owned process to kill; we intentionally do NOT
  ;; force-stop the user's browser.  Just forget our state.
  (setf (eservo--driver-opts driver) nil)
  t)

(defun eservo-adb--alive-p (_driver)
  (ignore-errors (string= (eservo-adb--run "get-state") "device")))

(defun eservo-adb--goto (driver url)
  (eservo-adb--run "shell" "am" "start" "-a"
                   "android.intent.action.VIEW" "-d" url
                   eservo-adb-browser-package)
  (setf (eservo--driver-url driver) url))

(defun eservo-adb--url (driver)
  (eservo--driver-url driver))

(defun eservo-adb--fill (driver selector text)
  "Tap SELECTOR (only \"text=...\" is supported) then type TEXT."
  (unless (and (stringp selector) (string-prefix-p "text=" selector))
    (error "eservo-adb: fill needs a \"text=...\" selector (no DOM on Android); got %S"
           selector))
  (eservo-adb--tap driver selector)
  (eservo-adb--run "shell" "input" "text"
                   (replace-regexp-in-string " " "%s" text)))

(defun eservo-adb--keys (driver keys)
  "Send KEYS: known tokens via keyevent, other words via input text."
  (dolist (tok (split-string keys "[ \t\n]+" t))
    (if-let* ((code (cdr (assoc (upcase tok) eservo-adb--keycodes))))
        (eservo-adb--run "shell" "input" "keyevent" (number-to-string code))
      (eservo-adb--run "shell" "input" "text" tok))))

(defun eservo-adb--wait (driver spec &optional _timeout)
  "Wait: numbers sleep; CSS selectors are impossible here."
  (if (numberp spec)
      (sit-for spec)
    (error "eservo-adb: selector waits unsupported (no DOM; use (wait N) or eservo-snapshot)")))

(defun eservo-adb--screenshot (driver file)
  "Screencap the device screen to FILE (PNG bytes via exec-out)."
  (let ((data (eservo-adb--run-raw "exec-out" "screencap" "-p")))
    (let ((coding-system-for-write 'no-conversion))
      (write-region data nil file))
    file))

(defun eservo-adb-make-backend ()
  "Build the adb backend (see `eservo-backend').
Ops left nil (extract, evaluate, cookies) surface as clear
\"backend `adb' does not support X\" errors from dispatch."
  (eservo-backend--make
   :name 'adb
   :start #'eservo-adb--start-op
   :stop #'eservo-adb--stop
   :alive-p #'eservo-adb--alive-p
   :goto #'eservo-adb--goto
   :url #'eservo-adb--url
   :snapshot #'eservo-adb--snapshot
   :fill #'eservo-adb--fill
   :click #'eservo-adb--tap
   :keys #'eservo-adb--keys
   :wait #'eservo-adb--wait
   :screenshot #'eservo-adb--screenshot))

(provide 'eservo-adb)
;;; eservo-adb.el ends here
