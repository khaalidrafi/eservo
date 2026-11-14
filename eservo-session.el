;;; eservo-session.el --- per-site browser sessions for eservo -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of eservo.  See the header of eservo.el for details.

;;; Commentary:

;; Log in ONCE per site, keep the session forever:
;;
;;   M-x eservo-session-login RET chat.qwen.ai   (headed browser opens)
;;   ... log in like a human ...
;;   M-x eservo-session-save RET chat.qwen.ai    (cookies + localStorage
;;                                                written to a 0600 file)
;;
;; Later runs restore with `eservo-session-load' (or the
;; (session-load "chat.qwen.ai") script step), so agents/scripts never
;; see a login page again.
;;
;; SECURITY (v0.1 contract):
;; - Session files contain cookie values and localStorage tokens -- they
;;   ARE credentials.  They are written with mode 0600 into
;;   `eservo-state-dir' (never inside the repo), and never logged.
;; - Human credentials come from `auth-source' ONLY
;;   (`eservo-credentials'); eservo never writes, prints or stores
;;   them.  Use ~/.authinfo.gpg.
;; - Note: the CDP backend also runs the browser with a persistent
;;   --user-data-dir under `eservo-state-dir', which itself keeps
;;   logins alive across restarts; the session files make restore
;;   explicit, portable and scriptable.

;;; Code:

(require 'auth-source)
(require 'json)
(require 'eservo)
(require 'eservo-backend)
(require 'eservo-cdp)                   ; for eservo-cdp-headless (login)

(defcustom eservo-session-dir nil
  "Directory for saved per-site sessions.
nil means `eservo-state-dir'/sessions.  The directory is created with
mode 0700; session files get mode 0600.  Override only if you keep the
dir somewhere already protected."
  :group 'eservo
  :type '(choice (const :tag "Under eservo-state-dir" nil) directory))

(defun eservo-session--dir ()
  "Return (and create, 0700) the session directory."
  (let ((dir (or eservo-session-dir
                 (expand-file-name "sessions"
                                   (file-name-as-directory
                                    eservo-state-dir)))))
    (unless (file-directory-p dir)
      (make-directory dir t)
      (set-file-modes dir #o700))
    dir))

(defun eservo-session--file (site)
  "File name for SITE's saved session (site name sanitized)."
  (expand-file-name
   (concat (replace-regexp-in-string "[^[:alnum:].-]" "-"
                                     (downcase site))
           ".json")
   (eservo-session--dir)))

(defun eservo-credentials (site)
  "Return (USER . SECRET) for SITE from `auth-source'.
SITE matches the `machine' field of the authinfo entry.  The secret
is never printed, stored or logged by eservo.  Add entries to
~/.authinfo.gpg like:
  machine chat.qwen.ai login you@example.com password SECRET"
  (let* ((found (auth-source-search :max 1 :host site
                                    :require '(:user :secret)))
         (entry (car found)))
    (unless entry
      (error
       "eservo: no auth-source entry for host %S (add `machine %s login USER password SECRET' to ~/.authinfo.gpg)"
       site site))
    (cons (plist-get entry :user)
          (let ((f (plist-get entry :secret)))
            (if (functionp f) (funcall f) f)))))

(defconst eservo-session--dump-js
  ;; Serialize everything we need to rebuild the login state.  Only the
  ;; JSON STRING travels back via returnByValue, which keeps the shape
  ;; stable between CDP versions.
  "(function(){
  var pick=function(store){var o={};for(var i=0;i<store.length;i++){var k=store.key(i);o[k]=store.getItem(k);}return o;};
  return JSON.stringify({origin:location.origin,
                         local:pick(localStorage),
                         session:pick(sessionStorage)});
})()")

(defun eservo-session-save (site)
  "Save the current browser session as SITE (cookies + web storage).
Returns the file path.  Values are written to a 0600 file under
`eservo-session--dir' and are never echoed."
  (interactive "Meservo save session as site: ")
  (let* ((driver (eservo--driver-or-error))
         (cookies (eservo-backend-call driver 'cookies-get))
         (storage (eservo-backend-call driver 'evaluate
                                       eservo-session--dump-js)))
    (unless (stringp storage)
      (error "eservo: could not read web storage for %S" site))
    (let* ((file (eservo-session--file site))
           ;; Keep only the fields we need; this is the whole secret
           ;; payload, so the file MUST stay 0600 (set below).
           (data (json-encode
                  `((site . ,site)
                    (saved-at . ,(format-time-string "%FT%T%z"))
                    (cookies . ,cookies)
                    (storage . ,(json-parse-string storage
                                                   :object-type 'alist
                                                   :array-type 'list
                                                   :null-object nil
                                                   :false-object nil))))))
      (with-temp-file file
        (insert data))
      (set-file-modes file #o600)
      (message "eservo: session %s saved (%d cookies) to %s"
               site (length cookies) file)
      file)))

(defun eservo-session-load (site &optional url)
  "Restore the session saved as SITE into the current browser.
Restores cookies, navigates to the saved origin to re-apply
localStorage/sessionStorage, then (optionally) goes to URL.
Returns the saved origin."
  (interactive "Meservo load session: ")
  (let* ((driver (eservo--driver-or-error))
         (file (eservo-session--file site)))
    (unless (file-exists-p file)
      (error "eservo: no saved session for %S (run eservo-session-save first)" site))
    (let* ((data (with-temp-buffer
                   (insert-file-contents file)
                   (json-parse-string (buffer-string)
                                      :object-type 'alist
                                      :array-type 'list
                                      :null-object nil :false-object nil)))
           (storage (cdr (assoc 'storage data)))
           (cookies (cdr (assoc 'cookies data)))
           (origin (or (cdr (assoc 'origin storage)) (cdr (assoc 'site data)))))
      ;; Cookies first (they may be needed for the origin visit), then
      ;; storage, which is only writable on its own origin.
      (when cookies (eservo-backend-call driver 'cookies-set cookies))
      (eservo-backend-call driver 'goto origin)
      (eservo-backend-call driver 'evaluate
                           (format "(function(){var d=JSON.parse(%s);for(var k in d.local){localStorage.setItem(k,d.local[k]);}for(var k in d.session){sessionStorage.setItem(k,d.session[k]);}return true;})()"
                                   (json-encode (json-encode storage))))
      ;; Optional final hop (docstring promised it; landing it here).
      (when url (eservo-backend-call driver 'goto url))
      (message "eservo: session %s restored (%d cookies)" site (length cookies))
      origin)))

(defun eservo-session-login (site &optional url)
  "Open SITE in a HEADED browser so a human can log in once.
Any previous browser is stopped first (headless sessions would be
invisible).  After logging in, run `eservo-session-save' with the
same SITE name.  On Termux/Android, Termux:API/X11 users may need
`eservo-cdp-headless' handled manually -- see README.org."
  (interactive "Meservo login to site: ")
  (when (and eservo--current-driver
             (eservo-backend-call eservo--current-driver 'alive-p))
    (eservo-stop))
  ;; Human logins need a visible window; override headless just for
  ;; this launch (the CDP backend reads it at start time).
  (let ((eservo-cdp-headless nil))
    (eservo-start)
    (eservo-goto (or url (concat "https://" site))))
  (message
   "eservo: log in to %s in the browser window, then run M-x eservo-session-save RET %s"
   site site))

(provide 'eservo-session)
;;; eservo-session.el ends here
