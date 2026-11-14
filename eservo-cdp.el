;;; eservo-cdp.el --- Chromium DevTools Protocol backend for eservo -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of eservo.  See the header of eservo.el for details.

;;; Commentary:

;; CDP backend: launch chromium/chrome (or attach to a running one) and
;; drive it over the DevTools Protocol.
;;
;; Transport: `eservo-ws' (pure-Elisp WebSocket) + url.el for the HTTP
;; target discovery at http://127.0.0.1:PORT/json.  We talk to the
;; *page* target's WebSocket directly, which avoids Target/flatten
;; session bookkeeping entirely.
;;
;; All calls are synchronous (send -> wait for the matching id) so that
;; interactive commands and deterministic scripts are simple and
;; agent-friendly.
;;
;; Design notes:
;; - BINARIES: chromium is resolved from PATH (`executable-find'), never
;;   hardcoded /usr paths, so Termux and Guix both work.
;; - REACT-SAFE FILL: setting .value directly does not notify React/Vue
;;   sites; we use the native prototype setter + input/change events.
;; - REFS: `snapshot' stamps interactive elements with an `esvref'
;;   attribute in the live DOM; `click' then targets [esvref="N"].

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)
(require 'url-parse)
(require 'eservo-backend)
(require 'eservo-ws)

(defgroup eservo-cdp nil
  "Chrome DevTools Protocol backend for eservo."
  :group 'eservo)

(defcustom eservo-cdp-program
  '("chromium" "chromium-browser" "google-chrome-stable"
    "google-chrome" "chrome" "msedge" "brave-browser")
  "Browser executable(s) tried in order via `executable-find' (PATH).
May be a list or a single string.  Resolving from PATH (instead of
hardcoding /usr/bin/...) keeps Guix and Termux/Android working."
  :group 'eservo-cdp
  :type '(choice (repeat string) string))

(defcustom eservo-cdp-port nil
  "When non-nil (an integer), ATTACH to a browser already listening on
this DevTools port instead of launching a new one.  Useful for sharing
one browser between eservo sessions and for the test suite."
  :group 'eservo-cdp
  :type '(choice (const :tag "Launch a new browser" nil) integer))

(defcustom eservo-cdp-headless t
  "Launch the browser headless by default.  Set nil to see the window
(e.g. for `eservo-session-login' where a human logs in)."
  :group 'eservo-cdp
  :type 'boolean)

(defcustom eservo-cdp-extra-args nil
  "Extra command-line args passed to the browser on launch."
  :group 'eservo-cdp
  :type '(repeat string))

(defcustom eservo-cdp-profile-dir nil
  "Browser --user-data-dir.  nil means a persistent profile under
`eservo-state-dir', so logins survive between eservo runs."
  :group 'eservo-cdp
  :type '(choice (const :tag "Default profile under eservo-state-dir" nil)
                 directory))

(defcustom eservo-cdp-timeout 30
  "Seconds to wait for one CDP command response (and for page waits)."
  :group 'eservo-cdp
  :type 'number)

(defcustom eservo-cdp-max-elements 250
  "Maximum number of elements listed in one snapshot outline."
  :group 'eservo-cdp
  :type 'integer)

(defconst eservo-cdp--launch-timeout 20
  "Seconds to wait for a freshly launched browser to open DevTools.")

;; ----- connection state ----------------------------------------------

(cl-defstruct (eservo-cdp--conn (:constructor eservo-cdp--conn-new))
  "One CDP WebSocket connection to a page target."
  ws                       ; the `eservo-ws' object
  pending                  ; hash TABLE id -> (:done :result :error) plist
  next-id)                 ; last JSON-RPC id used

;; ----- HTTP target discovery (url.el) --------------------------------

(defun eservo-cdp--http-json (port path)
  "GET http://127.0.0.1:PORT/PATH and parse the JSON body (alist)."
  (let* ((url (format "http://127.0.0.1:%d%s" port path))
         ;; CDP is always local; never route it through a proxy.
         (url-proxy-services nil)
         ;; The 5-arg (timeout) form of this function is not available
         ;; in all Emacsen; localhost connections fail fast anyway.
         (buf (url-retrieve-synchronously url nil nil nil)))
    (unless buf
      (error "eservo-cdp: no HTTP response from %s" url))
    (with-current-buffer buf
      (goto-char (point-min))
      (let ((body (when (re-search-forward "\r?\n\r?\n" nil t)
                    (buffer-substring-no-properties (point) (point-max)))))
        (kill-buffer buf)
        (unless body
          (error "eservo-cdp: malformed HTTP response from %s" url))
        (json-parse-string body :object-type 'alist :array-type 'list
                           ;; CDP JSON uses null/false freely; Emacs 30
                           ;; requires an explicit mapping for alists.
                           ;; false and null both become nil here, which
                           ;; is fine for the fields eservo reads.
                           :null-object nil :false-object nil)))))

;; ----- JSON-RPC over the WebSocket -----------------------------------

(defun eservo-cdp--ws-callback (conn text)
  "WebSocket callback: route JSON-RPC responses to waiting RPCs.
Events (messages with \"method\") are ignored for now; page waits are
done by polling, which keeps the state machine trivial."
  (condition-case err
      (let ((msg (json-parse-string text :object-type 'alist :array-type 'list
                                    :null-object nil :false-object nil)))
        (when-let* ((id (cdr (assoc 'id msg)))
                    (entry (gethash id (eservo-cdp--conn-pending conn))))
          ;; plist-put mutates in place; the RPC loop is polling this.
          (plist-put entry :done t)
          (if (assoc 'error msg)
              (plist-put entry :error (cdr (assoc 'error msg)))
            (plist-put entry :result (cdr (assoc 'result msg))))))
    (error
     (message "eservo-cdp: dropped malformed ws message (%S)" err))))

(defun eservo-cdp--rpc (conn method &optional params timeout)
  "Send METHOD/PARAMS and wait for the matching response (synchronous).
Returns the `result' object as an alist, or signals an error on
timeout or when CDP returns an error object."
  (let* ((id (cl-incf (eservo-cdp--conn-next-id conn)))
         (msg `((id . ,id) (method . ,method))))
    (when params (setq msg (append msg `((params . ,params)))))
    (puthash id (list :done nil :result nil :error nil)
             (eservo-cdp--conn-pending conn))
    (eservo-ws-send (eservo-cdp--conn-ws conn) (json-encode msg))
    (let ((deadline (+ (float-time) (or timeout eservo-cdp-timeout)))
          entry)
      (while (progn (setq entry (gethash id (eservo-cdp--conn-pending conn)))
                    (not (plist-get entry :done)))
        (if (>= (float-time) deadline)
            (error "eservo-cdp: timeout waiting for `%s'" method))
        (accept-process-output (eservo-ws-proc (eservo-cdp--conn-ws conn))
                               0.1))
      (remhash id (eservo-cdp--conn-pending conn))
      (if (plist-get entry :error)
          (error "eservo-cdp: `%s' failed: %s" method
                 (let ((e (plist-get entry :error)))
                   (or (cdr (assoc 'message e)) (prin1-to-string e))))
        (plist-get entry :result)))))

(defun eservo-cdp--conn (driver)
  "Return the active `eservo-cdp--conn' of DRIVER, or error."
  (or (plist-get (eservo--driver-opts driver) :conn)
      (error "eservo-cdp: not started (run eservo-start first)")))

;; ----- JavaScript helpers --------------------------------------------

(defun eservo-cdp--evaluate (driver js)
  "Evaluate JS in the page; return its value (keyword :no-value if none)."
  (let* ((conn (eservo-cdp--conn driver))
         (res (eservo-cdp--rpc conn "Runtime.evaluate"
                               `((expression . ,js)
                                 (returnByValue . t)
                                 (awaitPromise . t))))
         ;; CDP shape: {result: {result: RemoteObject, exceptionDetails: ...}}
         (payload (cdr (assoc 'result res)))
         (obj (cdr (assoc 'result payload))))
    (when-let* ((ed (cdr (assoc 'exceptionDetails payload))))
      (error "eservo-cdp: JS exception: %s"
             (or (cdr (assoc 'text ed))
                 (cdr (assoc 'description ed))
                 (prin1-to-string ed))))
    (if (assoc 'value obj)
        (cdr (assoc 'value obj))
      :no-value)))

(defconst eservo-cdp--snapshot-js
  ;; Stamps every interactive element with esvref="N" and returns a
  ;; compact outline.  Hidden (zero-size) elements are skipped so the
  ;; agent sees what a user would see.
  (format "(function(){
  var out=[], n=0, max=%d;
  var sel='a,button,input,textarea,select,summary,h1,h2,h3,[role=button],[role=link],[role=tab],[role=checkbox],[role=menuitem],[contenteditable]';
  var els=document.querySelectorAll(sel);
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
})()"
          eservo-cdp-max-elements))

(defun eservo-cdp--snapshot (driver)
  "Return the compact DOM outline (string) with [N] element refs."
  (let ((outline (eservo-cdp--evaluate driver eservo-cdp--snapshot-js)))
    (format "URL: %s\n%s"
            (or (eservo-cdp--url driver) "?")
            (if (stringp outline) outline " (no elements)"))))

(defun eservo-cdp--goto (driver url)
  "Navigate to URL; return the resulting URL reported by CDP."
  (let* ((conn (eservo-cdp--conn driver))
         (res (eservo-cdp--rpc conn "Page.navigate" `((url . ,url)))))
    (setf (eservo--driver-url driver)
          (or (cdr (assoc 'url res)) url))))

(defun eservo-cdp--url (driver)
  (eservo--driver-url driver))

(defun eservo-cdp--fill (driver selector text)
  "Set SELECTOR's value to TEXT, firing input/change events.
The prototype-setter dance matters: React/Vue chat inputs ignore
plain assignment, which is exactly the qwen/z.ai case eservo targets."
  (let ((ok (eservo-cdp--evaluate
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
      (error "eservo-cdp: no element matching %S" selector))
    t))

(defun eservo-cdp--click (driver ref)
  "Click the element with esvref REF (number) or a CSS SELECTOR (string)."
  (let ((target (if (numberp ref)
                    (format "[esvref=\"%d\"]" ref)
                  (json-encode ref))))
    (let ((status (eservo-cdp--evaluate
                   driver
                   (format "(function(){
  var el=document.querySelector(%s);
  if(!el) return 'no-element';
  el.scrollIntoView({block:'center'});
  el.click();
  return 'ok';
})()" target))))
      (unless (string= status "ok")
        (error "eservo-cdp: cannot click %S (not found)" ref))
      t)))

(defconst eservo-cdp--special-keys
  ;; token -> (KEY CODE VK): CDP Input.dispatchKeyEvent fields.
  '(("RET"      "Enter"     "Enter"     13)
    ("ENTER"    "Enter"     "Enter"     13)
    ("TAB"      "Tab"       "Tab"        9)
    ("ESC"      "Escape"    "Escape"    27)
    ("ESCAPE"   "Escape"    "Escape"    27)
    ("DEL"      "Backspace" "Backspace"  8)
    ("BACKSPACE" "Backspace" "Backspace" 8)
    ("SPC"      " "         "Space"     32)
    ("UP"       "ArrowUp"   "ArrowUp"   38)
    ("DOWN"     "ArrowDown" "ArrowDown" 40)
    ("LEFT"     "ArrowLeft" "ArrowLeft" 37)
    ("RIGHT"    "ArrowRight" "ArrowRight" 39)
    ("PGUP"     "PageUp"    "PageUp"    33)
    ("PGDN"     "PageDown"  "PageDown"  34)
    ("HOME"     "Home"      "Home"      36)
    ("END"      "End"       "End"       35)
    ("DELETE"   "Delete"    "Delete"    46))
  "Emacs-ish key tokens accepted by `eservo-cdp--keys'.")

(defun eservo-cdp--dispatch-key (conn key code vk)
  "Send KEY as a CDP keyDown+keyUp pair."
  (dolist (type '("keyDown" "keyUp"))
    (eservo-cdp--rpc conn "Input.dispatchKeyEvent"
                     `((type . ,type)
                       (key . ,key)
                       (code . ,code)
                       (windowsVirtualKeyCode . ,vk)
                       (nativeVirtualKeyCode . ,vk)))))

(defun eservo-cdp--keys (driver keys)
  "Send KEYS: whitespace-separated tokens.  Recognized tokens (RET,
TAB, ESC, DEL, SPC, arrows...) are dispatched as real key events;
anything else is inserted as text (Input.insertText), which works for
React/Vue inputs and contenteditable."
  (let ((conn (eservo-cdp--conn driver)))
    (dolist (tok (split-string keys "[ \t\n]+" t))
      (if-let* ((spec (assoc (upcase tok) eservo-cdp--special-keys)))
          (eservo-cdp--dispatch-key conn
                                    (nth 1 spec) (nth 2 spec) (nth 3 spec))
        (eservo-cdp--rpc conn "Input.insertText" `((text . ,tok)))))))

(defun eservo-cdp--wait (driver spec &optional timeout)
  "Wait for SPEC: a number = sleep that many seconds; a string =
poll the page until CSS selector SPEC exists (up to TIMEOUT or
`eservo-cdp-timeout')."
  (if (numberp spec)
      (sit-for spec)
    (let* ((sel spec)
           (timeout (or timeout eservo-cdp-timeout))
           (deadline (+ (float-time) timeout)))
      (while (not (eservo-cdp--evaluate
                   driver (concat "!!document.querySelector("
                                  (json-encode sel) ")")))
        (when (>= (float-time) deadline)
          (error "eservo-cdp: timed out waiting for selector %S" sel))
        (sit-for 0.5)))))

(defun eservo-cdp--extract (driver selector)
  "Return text of all elements matching SELECTOR, joined by blank lines."
  (let ((text (eservo-cdp--evaluate
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

(defun eservo-cdp--screenshot (driver file)
  "Best-effort PNG screenshot to FILE via Page.captureScreenshot."
  (let* ((conn (eservo-cdp--conn driver))
         (res (eservo-cdp--rpc conn "Page.captureScreenshot"
                               '((format . "png"))))
         (data (cdr (assoc 'data res))))
    (unless data
      (error "eservo-cdp: screenshot failed"))
    (make-directory (file-name-directory (expand-file-name file)) t)
    ;; base64-decode-string yields raw bytes; write them verbatim.
    (let ((coding-system-for-write 'no-conversion))
      (write-region (base64-decode-string data) nil file))
    file))

(defun eservo-cdp--cookies-get (driver)
  "Return all browser cookies as a list of alists (Network.getAllCookies)."
  (let* ((conn (eservo-cdp--conn driver))
         (res (eservo-cdp--rpc conn "Network.getAllCookies")))
    (cdr (assoc 'cookies res))))

(defun eservo-cdp--cookies-set (driver cookies)
  "Restore COOKIES (list of alists from `eservo-cdp--cookies-get')."
  (let ((conn (eservo-cdp--conn driver)))
    (dolist (cookie cookies)
      (eservo-cdp--rpc conn "Network.setCookie" cookie))))

;; ----- start / stop ---------------------------------------------------

(defun eservo-cdp--find-program ()
  "Resolve the browser executable from PATH."
  (if (stringp eservo-cdp-program)
      (or (executable-find eservo-cdp-program)
          (error "eservo-cdp: `%s' not found in PATH" eservo-cdp-program))
    (or (seq-some #'executable-find (remq nil (append eservo-cdp-program nil)))
        (error "eservo-cdp: no chromium/chrome in PATH; set `eservo-cdp-program'"))))

(defun eservo-cdp--profile-dir ()
  "Persistent per-user profile dir (keeps logins across runs)."
  (or eservo-cdp-profile-dir
      (expand-file-name "profile" (file-name-as-directory eservo-state-dir))))

(defun eservo-cdp--launch (driver)
  "Start a browser process with an ephemeral DevTools port, attach."
  (let* ((prog (eservo-cdp--find-program))
         (proc (apply #'start-process "eservo-browser"
                      "*eservo-cdp-proc*" prog
                      (append
                       (when eservo-cdp-headless '("--headless=new"))
                       ;; Port 0: the OS picks a free port; chromium
                       ;; prints "DevTools listening on ws://..:PORT"
                       ;; on stderr, which we parse below.  No fixed
                       ;; port means parallel sessions never collide.
                       '("--remote-debugging-port=0")
                       (list (concat "--user-data-dir=" (eservo-cdp--profile-dir)))
                       '("--no-first-run" "--no-default-browser-check"
                         "--disable-background-networking")
                       eservo-cdp-extra-args
                       '("about:blank"))))
         (deadline (+ (float-time) eservo-cdp--launch-timeout))
         port)
    (setf (eservo--driver-opts driver)
          (list :proc proc))
    (while (and (null port) (< (float-time) deadline))
      (unless (process-live-p proc)
        (error "eservo-cdp: browser exited early; see buffer *eservo-cdp-proc*"))
      (accept-process-output proc 0.25)
      (with-current-buffer (process-buffer proc)
        (save-excursion
          (goto-char (point-min))
          (when (re-search-forward
                 "DevTools listening on ws://[^[:space:]]+:\\([0-9]+\\)" nil t)
            (setq port (string-to-number (match-string 1)))))))
    (unless port
      (error "eservo-cdp: browser did not open DevTools within %ss"
             eservo-cdp--launch-timeout))
    (eservo-cdp--attach driver port)))

(defun eservo-cdp--attach (driver port)
  "Connect DRIVER to the first page target of the browser on PORT."
  (let* ((targets (eservo-cdp--http-json port "/json"))
         (page (seq-find (lambda (tg)
                           (string= (or (cdr (assoc 'type tg)) "") "page"))
                         targets)))
    (unless page
      (error "eservo-cdp: no page target on port %d" port))
    (let* ((wsurl (cdr (assoc 'webSocketDebuggerUrl page)))
           (m (and wsurl
                   (string-match
                    "^ws://\\([^:/]+\\):\\([0-9]+\\)\\(/.*\\)$" wsurl))))
      (unless m
        (error "eservo-cdp: target has no usable webSocketDebuggerUrl"))
      (let* ((ws (eservo-ws-connect (match-string 1 wsurl)
                                    (string-to-number (match-string 2 wsurl))
                                    (match-string 3 wsurl)
                                    (lambda (_ws text)
                                      (eservo-cdp--ws-callback
                                       (plist-get (eservo--driver-opts driver)
                                                  :conn)
                                       text))))
             (conn (eservo-cdp--conn-new
                    :ws ws
                    :pending (make-hash-table :test 'eql)
                    :next-id 0)))
        (setf (eservo--driver-opts driver)
              (list :conn conn
                    :proc (plist-get (eservo--driver-opts driver) :proc)
                    :port port))
        ;; Enable the domains we use; harmless if already enabled.
        (eservo-cdp--rpc conn "Page.enable")
        (eservo-cdp--rpc conn "Network.enable")
        (setf (eservo--driver-url driver)
              (or (cdr (assoc 'url page)) "about:blank"))
        t))))

(defun eservo-cdp--start-op (driver)
  "Backend start op: launch (default) or attach, per `eservo-cdp-port'."
  (if eservo-cdp-port
      (eservo-cdp--attach driver eservo-cdp-port)
    (eservo-cdp--launch driver)))

(defun eservo-cdp--stop (driver)
  "Close the WebSocket and terminate a browser we launched."
  (let ((conn (plist-get (eservo--driver-opts driver) :conn)))
    (when conn (ignore-errors (eservo-ws-close (eservo-cdp--conn-ws conn)))))
  (let ((proc (plist-get (eservo--driver-opts driver) :proc)))
    (when (and proc (process-live-p proc))
      (delete-process proc)))
  (setf (eservo--driver-opts driver) nil)
  t)

(defun eservo-cdp--alive-p (driver)
  (let ((conn (plist-get (eservo--driver-opts driver) :conn)))
    (and conn
         (not (eservo-ws-closed (eservo-cdp--conn-ws conn)))
         (let ((proc (plist-get (eservo--driver-opts driver) :proc)))
           (or (null proc) (process-live-p proc))))))

(defun eservo-cdp-make-backend ()
  "Build the CDP backend (see `eservo-backend')."
  (eservo-backend--make
   :name 'cdp
   :start #'eservo-cdp--start-op
   :stop #'eservo-cdp--stop
   :alive-p #'eservo-cdp--alive-p
   :goto #'eservo-cdp--goto
   :url #'eservo-cdp--url
   :snapshot #'eservo-cdp--snapshot
   :fill #'eservo-cdp--fill
   :click #'eservo-cdp--click
   :keys #'eservo-cdp--keys
   :wait #'eservo-cdp--wait
   :extract #'eservo-cdp--extract
   :screenshot #'eservo-cdp--screenshot
   :evaluate #'eservo-cdp--evaluate
   :cookies-get #'eservo-cdp--cookies-get
   :cookies-set #'eservo-cdp--cookies-set))

(provide 'eservo-cdp)
;;; eservo-cdp.el ends here
