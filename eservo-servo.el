;;; eservo-servo.el --- Servo engine backend for eservo -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of eservo.  See the header of eservo.el for details.

;;; Commentary:

;; The Servo backend: eservo's native-engine option, driven over
;; Servo's devtools server (Firefox RDP; see eservo-rdp.el).  Servo
;; is started with `--devtools=PORT' (or attached to when it already
;; runs), and every op -- goto, snapshot, fill, click, keys, wait,
;; extract, evaluate -- is executed as JavaScript in the live page
;; through the console actor's evaluateJS.
;;
;; Two ways up:
;;
;; - LAUNCH (desktop Linux): `eservo-servo-port' nil (default) starts
;;   `servoshell' (or `servo') from PATH with an ephemeral devtools
;;   port and about:blank, then attaches.
;;
;; - ATTACH (Android/Termux, remote, or shared): set `eservo-servo-port'
;;   (and `eservo-servo-host' when not on this machine) to a servo
;;   already running with --devtools.  From Termux Emacs this is how a
;;   servo on the same device -- or on a desktop over the LAN -- becomes
;;   the embedded engine for Emacs.  The servo Android app
;;   (org.servo.servoshell, servo.org nightlies) can also be driven at
;;   the UI level with the adb backend: set
;;   `eservo-adb-browser-package' to "org.servo.servoshell".
;;
;; HONEST LIMITS of the devtools subset Servo implements today:
;; - No screenshot and no cookie access over RDP: those ops are nil
;;   and surface as clear "backend `servo' does not support X" errors.
;; - `keys' synthesizes KeyboardEvent/input events from JS -- they are
;;   NOT trusted browser input events (unlike the cdp backend).  Plain
;;   forms work; sites that require trusted key events may not react.
;;   Prefer `fill' wherever possible.
;; - Sessions (cookie/localStorage persistence via eservo-session)
;;   depend on the cookies ops and therefore do not work here.

;;; Code:

(require 'cl-lib)
(require 'eservo-backend)
(require 'eservo-rdp)

(defgroup eservo-servo nil
  "Servo engine backend for eservo."
  :group 'eservo)

(defcustom eservo-servo-program '("servoshell" "servo")
  "Servo executable(s) tried in order via `executable-find' (PATH).
The official servo.org nightly tarball ships `servoshell'."
  :group 'eservo-servo
  :type '(choice (repeat string) string))

(defcustom eservo-servo-port nil
  "When non-nil (integer), ATTACH to a servo already listening with
--devtools on this port instead of launching one.  nil launches."
  :group 'eservo-servo
  :type '(choice (const :tag "Launch a new servo" nil) integer))

(defcustom eservo-servo-host "127.0.0.1"
  "Host of the devtools server for attach mode.
Point at a desktop machine to drive its servo from Android/Termux."
  :group 'eservo-servo
  :type 'string)

(defcustom eservo-servo-extra-args nil
  "Extra command-line args for the launched servo (desktop only)."
  :group 'eservo-servo
  :type '(repeat string))

(defcustom eservo-servo-max-elements 250
  "Maximum number of elements listed in one snapshot outline."
  :group 'eservo-servo
  :type 'integer)

(defconst eservo-servo--launch-timeout 20
  "Seconds to wait for a freshly launched servo to open devtools.")

;; ----- connection plumbing --------------------------------------------

(defun eservo-servo--find-program ()
  "Resolve the servo executable from PATH."
  (if (stringp eservo-servo-program)
      (or (executable-find eservo-servo-program)
          (error "eservo-servo: `%s' not found in PATH" eservo-servo-program))
    (or (seq-some #'executable-find
                  (remq nil (append eservo-servo-program nil)))
        (error "eservo-servo: no servoshell/servo in PATH; set `eservo-servo-program' (or attach with `eservo-servo-port')"))))

(defun eservo-servo--free-port ()
  "Pick an unused TCP port by briefly listening on port 0."
  (let* ((probe (make-network-process :name "eservo-port-probe"
                                      :server t :service 0
                                      :host "127.0.0.1"))
         (port (cadr (process-contact probe))))
    (delete-process probe)
    port))

(defun eservo-servo--connect (host port)
  "Open an RDP connection, retrying while servo is still booting."
  (let ((deadline (+ (float-time) eservo-servo--launch-timeout)))
    (cl-block try
      (while t
        (let ((conn (ignore-errors (eservo-rdp-open host port))))
          (when conn (cl-return-from try conn)))
        (when (>= (float-time) deadline)
          (error "eservo-servo: no devtools server at %s:%d"
                 host port))
        (sit-for 0.5)))))

(defun eservo-servo--conn (driver)
  (plist-get (eservo--driver-opts driver) :conn))

(defun eservo-servo--console (driver)
  (plist-get (eservo--driver-opts driver) :console))

;; ----- evaluateJS: the one op everything else is built on -------------

(defun eservo-servo--eval (driver js)
  "Evaluate JS in the live page; return its value.
Signals on protocol errors and page exceptions (exceptionMessage)."
  (let* ((res (eservo-rdp-request
               (eservo-servo--conn driver)
               (eservo-servo--console driver)
               "evaluateJS" `((text . ,js)))))
    (when-let* ((err (assq 'error res)))
      (error "eservo-servo: devtools error: %s"
             (cdr (or (assq 'message res) err))))
    (when-let* ((exc (assq 'exceptionMessage res)))
      (error "eservo-servo: page JS error: %s" (cdr exc)))
    (if (assq 'result res) (cdr (assq 'result res)) :no-value)))

;; ----- ops -------------------------------------------------------------

(defun eservo-servo--start-op (driver)
  "Launch (desktop) or attach to a servo and wire the driver."
  (let* ((attach (when eservo-servo-port t))
         (port (or eservo-servo-port (eservo-servo--free-port)))
         (proc (unless attach
                 (apply #'start-process "eservo-servo" "*eservo-servo-proc*"
                        (eservo-servo--find-program)
                        (append eservo-servo-extra-args
                                (list (format "--devtools=%d" port)
                                      "about:blank")))))
         (conn (eservo-servo--connect eservo-servo-host port))
         ;; Match on the tabs field: from-root packets that raced in
         ;; earlier (connect echoes, tabListChanged notifications)
         ;; must never be mistaken for this reply.
         (tabs-reply (eservo-rdp-request conn "root" "listTabs" nil
                                         (lambda (r) (assq 'tabs r))))
         (tabs (cdr (assq 'tabs tabs-reply))))
    (unless (and tabs (listp tabs) (seq-some #'identity tabs))
      (eservo-rdp-close conn)
      (when proc (delete-process proc))
      (error "eservo-servo: devtools server answered without tabs (%s)"
             (cdr (assq 'error tabs-reply))))
    (let* ((tab (or (nth (or (cdr (assq 'selected tabs-reply)) 0)
                          (append tabs nil))
                    (car (append tabs nil))))
           (console (cdr (assq 'consoleActor tab)))
           (url (cdr (assq 'url tab))))
      (unless console
        (eservo-rdp-close conn)
        (when proc (delete-process proc))
        (error "eservo-servo: tab actor gave no consoleActor"))
      (setf (eservo--driver-opts driver)
            (list :conn conn :console console :proc proc :port port
                  :attach attach))
      (setf (eservo--driver-url driver) url)
      t)))

(defun eservo-servo--stop (driver)
  (let ((opts (eservo--driver-opts driver)))
    (eservo-rdp-close (plist-get opts :conn))
    ;; Only a servo WE launched gets killed; an attached one is not
    ;; ours to stop (same law as the cdp attach mode).
    (when (and (plist-get opts :proc)
               (process-live-p (plist-get opts :proc)))
      (delete-process (plist-get opts :proc)))
    (setf (eservo--driver-opts driver) nil)
    t))

(defun eservo-servo--alive-p (driver)
  (eservo-rdp-alive-p (eservo-servo--conn driver)))

(defun eservo-servo--goto (driver url)
  (eservo-servo--eval
   driver
   (format "(function(){location.href=%s;return 'navigating';})()"
           (json-encode url)))
  ;; Navigation destroys the old document; give the new one a beat.
  (sit-for 0.3)
  (setf (eservo--driver-url driver) url))

(defun eservo-servo--url (driver)
  (let ((url (eservo-servo--eval driver "location.href")))
    (when (stringp url)
      (setf (eservo--driver-url driver) url))
    (eservo--driver-url driver)))

(defun eservo-servo--snapshot (driver)
  "Return the compact DOM outline (string) with [N] element refs.
Same outline shape and esvref stamping as the cdp backend, so agents
read both identically."
  (let ((outline
         (eservo-servo--eval
          driver
          (format "(function(){
  var sel='a,button,input,select,textarea,[role=button],[onclick],[contenteditable=true]';
  var els=document.querySelectorAll(sel), out=[], n=0, max=%d;
  for (var i=0;i<els.length && n<max;i++){
    var el=els[i], r=el.getBoundingClientRect();
    if ((r.width===0 && r.height===0)) continue;
    n++;
    el.setAttribute('esvref',String(n));
    var label=(el.innerText||el.value||el.placeholder||el.getAttribute('aria-label')||'').replace(/\\s+/g,' ').trim().slice(0,120);
    var t=el.tagName.toLowerCase();
    if(t==='a') t='link';
    else if(t==='button'||el.getAttribute('role')==='button') t='button';
    else if(t==='input') t='input'+(el.type?'('+el.type+')':'');
    out.push('['+n+'] '+t+' \"'+label+'\"');
  }
  if (els.length>max) out.push('... ('+(els.length-max)+' more, not shown)');
  return out.join('\\n');
})()" eservo-servo-max-elements))))
    (format "URL: %s\n%s"
            (or (eservo--driver-url driver) "?")
            (if (stringp outline) outline " (no elements)"))))

(defun eservo-servo--fill (driver selector text)
  "Set SELECTOR's value to TEXT, firing input/change events.
Same prototype-setter dance as the cdp backend: React/Vue inputs
ignore plain assignment."
  (let ((ok (eservo-servo--eval
             driver
             (format "(function(){
  var el=document.querySelector(%s);
  if(!el) return false;
  el.focus();
  var proto=(el instanceof HTMLTextAreaElement) ? HTMLTextAreaElement.prototype
           :(el instanceof HTMLInputElement) ? HTMLInputElement.prototype : null;
  if (proto) {
    var set=Object.getOwnPropertyDescriptor(proto,'value').set;
    set.call(el,%s);
    el.dispatchEvent(new Event('input',{bubbles:true}));
    el.dispatchEvent(new Event('change',{bubbles:true}));
  } else { el.textContent=%s; }
  return true;
})()"
                     (json-encode selector)
                     (json-encode text)
                     (json-encode text)))))
    (unless (eq ok t)
      (error "eservo-servo: no element matching %S" selector))
    t))

(defun eservo-servo--click (driver ref)
  "Click the element with esvref REF (number) or a CSS SELECTOR."
  (let* ((target (if (numberp ref)
                     (format "[esvref=\"%d\"]" ref)
                   ref))
         (status (eservo-servo--eval
                  driver
                  (format "(function(){
  var el=document.querySelector(%s);
  if(!el) return 'no-element';
  el.scrollIntoView({block:'center'});
  el.click();
  return 'ok';
})()" (json-encode target)))))
    (unless (string= status "ok")
      (error "eservo-servo: cannot click %S (not found)" ref))
    t))

(defconst eservo-servo--special-keys
  ;; token -> (KEY CODE): the fields of a synthetic KeyboardEvent.
  '(("RET" "Enter" "Enter") ("ENTER" "Enter" "Enter")
    ("TAB" "Tab" "Tab") ("ESC" "Escape" "Escape")
    ("ESCAPE" "Escape" "Escape") ("DEL" "Backspace" "Backspace")
    ("BACKSPACE" "Backspace" "Backspace") ("SPC" " " "Space")
    ("UP" "ArrowUp" "ArrowUp") ("DOWN" "ArrowDown" "ArrowDown")
    ("LEFT" "ArrowLeft" "ArrowLeft") ("RIGHT" "ArrowRight" "ArrowRight")
    ("PGUP" "PageUp" "PageUp") ("PGDN" "PageDown" "PageDown")
    ("HOME" "Home" "Home") ("END" "End" "End")
    ("DELETE" "Delete" "Delete"))
  "Emacs-ish key tokens accepted by `eservo-servo--keys'.")

(defun eservo-servo--keys (driver keys)
  "Send KEYS: whitespace-separated tokens.  Recognized tokens are
dispatched as synthetic keydown+keyup pairs; other tokens are
appended to the focused input via the prototype setter (React-safe)
with an execCommand insertText fallback for contenteditable.
Untrusted events -- see the file header LIMITS."
  (dolist (tok (split-string keys "[ \t\n]+" t))
    (if-let* ((spec (assoc (upcase tok) eservo-servo--special-keys)))
        (eservo-servo--eval
         driver
         (format "(function(){
  var el=document.activeElement||document.body;
  var init={key:%s,code:%s,bubbles:true,cancelable:true};
  el.dispatchEvent(new KeyboardEvent('keydown',init));
  el.dispatchEvent(new KeyboardEvent('keyup',init));
  return 'ok';
})()" (json-encode (nth 1 spec)) (json-encode (nth 2 spec))))
      (eservo-servo--eval
       driver
       (format "(function(){
  var el=document.activeElement;
  if(el&&(el.tagName==='INPUT'||el.tagName==='TEXTAREA')){
    var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto,'value').set.call(el, el.value+%s);
    el.dispatchEvent(new Event('input',{bubbles:true}));
    el.dispatchEvent(new Event('change',{bubbles:true}));
    return 'ok';
  }
  if(document.execCommand('insertText',false,%s)) return 'ok';
  return 'no-target';
})()" (json-encode tok) (json-encode tok))))))

(defun eservo-servo--wait (driver spec &optional timeout)
  "Wait for SPEC: a number = sleep; a string = poll a CSS selector."
  (if (numberp spec)
      (sit-for spec)
    (let* ((sel spec)
           (timeout (or timeout eservo-rdp-timeout))
           (deadline (+ (float-time) timeout)))
      (while (not (eservo-servo--eval
                   driver
                   (concat "!!document.querySelector("
                           (json-encode sel) ")")))
        (when (>= (float-time) deadline)
          (error "eservo-servo: timed out waiting for selector %S" sel))
        (sit-for 0.5)))))

(defun eservo-servo--extract (driver selector)
  "Return text of all elements matching SELECTOR, joined by blank lines."
  (let ((text (eservo-servo--eval
               driver
               (format "(function(){
  var els=document.querySelectorAll(%s), out=[];
  for (var i=0;i<els.length;i++){
    var e=els[i];
    out.push(e.innerText||e.value||e.textContent||'');
  }
  return out.join('\\n\\n');
})()" (json-encode selector)))))
    (if (stringp text) text "")))

(defun eservo-servo--evaluate (driver js)
  "Evaluate JS; return its value or :no-value."
  (eservo-servo--eval driver js))

(defun eservo-servo-make-backend ()
  "Build the servo backend (see `eservo-backend').
Screenshot and cookie ops are nil on purpose: servo's RDP devtools
subset has neither; dispatch turns them into clear errors."
  (eservo-backend--make
   :name 'servo
   :start #'eservo-servo--start-op
   :stop #'eservo-servo--stop
   :alive-p #'eservo-servo--alive-p
   :goto #'eservo-servo--goto
   :url #'eservo-servo--url
   :snapshot #'eservo-servo--snapshot
   :fill #'eservo-servo--fill
   :click #'eservo-servo--click
   :keys #'eservo-servo--keys
   :wait #'eservo-servo--wait
   :extract #'eservo-servo--extract
   :evaluate #'eservo-servo--evaluate))

(provide 'eservo-servo)
;;; eservo-servo.el ends here
