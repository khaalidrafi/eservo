;;; eservo.el --- Emacs-driven web automation (browser as a tool) -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: eservo contributors
;; Version: 0.1
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/khaalidrafi/eservo
;; Keywords: tools automation browser agent

;; This file is part of eservo.
;;
;; eservo is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; eservo is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with eservo.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; eservo drives a web browser from Emacs: point it at chromium/chrome
;; (or a device browser over adb) and use small commands -- goto,
;; snapshot, fill, click, keys, wait, extract -- either interactively,
;; from deterministic scripts (`eservo-script-run', no AI involved),
;; or as TOOLS for an LLM agent.  `eservo-agent-brief' prints the tool
;; menu plus the current page snapshot; that is the entry point for any
;; web/cloud agent that drives the browser through Emacs.
;;
;; Design rules (why it is this small):
;; - Pure Elisp + external child processes only: runs on Linux desktop,
;;   TTY (`emacs -nw') and Android/Termux.  No xwidgets, no GUI libs.
;; - One live driver at a time (`eservo--current-driver'); a backend is
;;   just a bundle of primitive ops (see eservo-backend.el).
;; - Sessions: `eservo-session-save' / `eservo-session-load' persist
;;   cookies + localStorage per site; credentials come from
;;   `auth-source' only -- never plaintext, never printed.
;;
;; Typical agent cycle:
;;   M-x eservo-goto  M-x eservo-snapshot
;;   ... read refs [N] ... M-x eservo-click / eservo-fill ... repeat.
;; (A browser auto-starts on first use with the best backend that runs
;; here; M-x eservo-start is only needed to pin a specific backend.)

;;; Code:

(require 'cl-lib)
(require 'eservo-backend)

(defgroup eservo nil
  "Drive a web browser from Emacs (Linux/TTY/Android)."
  :prefix "eservo-"
  :group 'applications)

(defcustom eservo-backend 'auto
  "Backend used by `eservo-start'.
`auto' (the default) picks the first backend that can actually run
HERE, in this order: `embedded' (the libeservo module, when it is
installed and loadable), `cdp' (a chromium/chrome in PATH, or a
configured DevTools port), `servo' (servoshell/servo in PATH, a
configured devtools port, or the on-device servo APK lane on
Android) and `adb' (adb in PATH).  When nothing works the error
lists WHY each backend was rejected, instead of failing deep inside
one of them with a misleading message (e.g. \\='no chromium binary\\='
on a machine whose real problem is that the embedded module was
never installed).
An explicit value skips detection: `cdp' drives Chromium/Chrome via
the DevTools Protocol; `embedded' runs the servo engine INSIDE the
Emacs process through the optional libeservo dynamic module (M-x
eservo-embedded-load-module; see docs/EMBEDDED-SERVO.org); `servo'
drives a servo over its devtools server (launch on desktop, or
attach from Android/Termux via `eservo-servo-port'); `adb' drives an
Android device browser over `adb shell' (best effort)."
  :group 'eservo
  :type '(choice (const :tag "Auto-detect (embedded first)" auto)
                 (const :tag "Chromium/Chrome via CDP" cdp)
                 (const :tag "Servo engine embedded in Emacs" embedded)
                 (const :tag "Servo engine via RDP devtools" servo)
                 (const :tag "Android device via adb" adb)
                 (symbol :tag "Other registered backend")))

(defcustom eservo-auto-start t
  "When non-nil (the default), any eservo command that needs a
browser starts one automatically via `eservo-start' instead of
erroring \='no browser started\='.  Interactive use should never have
to know about `eservo-start' first -- that ceremony existed only for
the v0.1 script runner.  Set nil to restore the explicit-only
behavior (scripts that want to control WHEN a browser launches)."
  :group 'eservo
  :type 'boolean)

(defvar eservo--current-driver nil
  "The one live browser-driving session, or nil.
Set by `eservo-start', cleared by `eservo-stop'.")

(defconst eservo--auto-order '(embedded cdp servo adb)
  "Preference order `eservo-backend' \='auto' probes backends in.
Registry backends (registered by users/tests via
`eservo-backend-registry') are not probed: an unknown backend has no
availability probe, so auto would be guessing.  Name one explicitly.")

;; Probe-time references into the backend files (each is (require)d
;; on demand inside `eservo--backend-reason'; declaring them here
;; keeps byte-compile warning-free without loading eagerly).
(declare-function eservo-embedded-available-p "eservo-embedded" ())
(declare-function eservo-embedded-load-module "eservo-embedded" ())
(declare-function eservo-servo-android--am-executable "eservo-servo" ())
(defvar eservo-cdp-port nil)
(defvar eservo-cdp-program nil)
(defvar eservo-servo-port nil)
(defvar eservo-servo-program nil)
(defvar eservo-adb-program nil)

(defun eservo--backend-reason (name)
  "Return nil when backend NAME looks startable here, else a why-not string.
Best-effort and side-effect-light: probing `embedded' may LOAD the
module (loading it is what using it means); the other probes only
look for binaries and configured ports."
  (pcase name
    (`embedded
     (if (and (require 'eservo-embedded nil t)
              (or (eservo-embedded-available-p)
                  (condition-case nil
                      (progn (eservo-embedded-load-module) t)
                    (error nil))))
         nil
       "the libeservo module is not installed (docs/EMBEDDED-SERVO.org)"))
    (`cdp
     (if (and (require 'eservo-cdp nil t)
              (or eservo-cdp-port
                  (seq-some #'executable-find
                            (append eservo-cdp-program nil))))
         nil
       "no chromium/chrome in PATH (set `eservo-cdp-program')"))
    (`servo
     (if (and (require 'eservo-servo nil t)
              (or eservo-servo-port
                  (if (eq system-type 'android)
                      (eservo-servo-android--am-executable)
                    (seq-some #'executable-find
                              (append eservo-servo-program nil)))))
         nil
       "no servoshell/servo in PATH and no devtools port"))
    (`adb
     (if (and (require 'eservo-adb nil t)
              (executable-find eservo-adb-program))
         nil
       "no adb in PATH (Termux: pkg install android-tools)"))
    (_ (format "unknown backend `%s'" name))))

(defun eservo--resolve-backend ()
  "Return the backend symbol `eservo-start' should use now.
Honours `eservo-backend': \='auto probes `eservo--auto-order' and
returns the first startable backend, erroring with the collected
per-backend reasons when none is.  Any other value passes through
unchanged."
  (if (eq eservo-backend 'auto)
      (let ((reasons nil))
        (or (cl-some
             (lambda (name)
               (let ((reason (eservo--backend-reason name)))
                 (cond (reason (push (cons name reason) reasons) nil)
                       (t name))))
             eservo--auto-order)
            (error "eservo: no usable browser backend on this machine:%s"
                   (mapconcat (lambda (r)
                                (format "\n  %s: %s" (car r) (cdr r)))
                              (nreverse reasons)
                              ""))))
    eservo-backend))

(defun eservo--driver-or-error ()
  "Return the live driver, auto-starting one when `eservo-auto-start'.
A driver whose backend died is transparently restarted; a live one
is returned as-is.  With `eservo-auto-start' nil this is the old
explicit-only behavior with the helpful hint."
  (cond
   ((and eservo--current-driver
         (eservo-backend-call eservo--current-driver 'alive-p))
    eservo--current-driver)
   (eservo-auto-start
    (eservo-start))
   (t
    (error "eservo: no browser started (run M-x eservo-start)"))))

(defun eservo--backend-symbol ()
  "Backend symbol chosen by \\[universal-argument] or `eservo-backend'."
  (if current-prefix-arg
      (intern (completing-read "eservo backend: "
                               (cons 'auto
                                     (mapcar #'car
                                             (eservo-backend-registered)))
                               nil t))
    (if (eq eservo-backend 'auto)
        'auto
      eservo-backend)))

;;;###autoload
(defun eservo-start (&optional backend)
  "Start a browser session via BACKEND (default `eservo-backend').
With \\[universal-argument] prompt for the backend.
Returns the driver.  A DEAD previous driver is stopped quietly and
replaced; only a live one is an error (run `eservo-stop' first)."
  (interactive (list (eservo--backend-symbol)))
  (when (and eservo--current-driver
             (eservo-backend-call eservo--current-driver 'alive-p))
    (error "eservo: browser already started (run eservo-stop first)"))
  (when eservo--current-driver
    ;; Dead driver: stop quietly (backends tolerate double-stop) so its
    ;; resources are released before the replacement boots.
    (ignore-errors (eservo-backend-call eservo--current-driver 'stop)))
  (let* ((backend-name (if (memq backend '(nil auto))
                           (eservo--resolve-backend)
                         backend))
         (driver (eservo--driver-make
                  :backend (eservo-backend-make backend-name)
                  :name (symbol-name backend-name))))
    (eservo-backend-call driver 'start)
    (setq eservo--current-driver driver)
    (message "eservo: %s backend started at %s"
             backend-name (eservo-backend-call driver 'url))
    driver))

;;;###autoload
(defun eservo-stop ()
  "Stop the browser session and clear the driver.  Harmless if none."
  (interactive)
  (when eservo--current-driver
    (eservo-backend-call eservo--current-driver 'stop)
    (setq eservo--current-driver nil)
    (message "eservo: browser stopped"))
  nil)

(defun eservo-url ()
  "Return the current page URL."
  (eservo-backend-call (eservo--driver-or-error) 'url))

;;;###autoload
(defun eservo-goto (url)
  "Navigate the current browser to URL."
  (interactive "Meservo goto URL: ")
  (eservo-backend-call (eservo--driver-or-error) 'goto url))

;;;###autoload
(defun eservo-snapshot ()
  "Return a compact DOM outline with [N] element refs, and show it.
The refs are what `eservo-click' targets; agents read this text."
  (interactive)
  (let ((snap (eservo-backend-call (eservo--driver-or-error) 'snapshot)))
    (eservo--show "snapshot" snap)
    snap))

;;;###autoload
(defun eservo-fill (selector text)
  "Set SELECTOR's value to TEXT (React/Vue-safe input events)."
  (interactive "Meservo fill selector: \nMeservo fill text: ")
  (prog1 (eservo-backend-call (eservo--driver-or-error) 'fill selector text)
    (message "eservo: filled %s" selector)))

;;;###autoload
(defun eservo-click (ref)
  "Click element REF: a number from `eservo-snapshot' or a CSS selector."
  (interactive "Meservo click (ref number or CSS selector): ")
  (setq ref (eservo--maybe-number ref))
  (prog1 (eservo-backend-call (eservo--driver-or-error) 'click ref)
    (message "eservo: clicked %s" ref)))

;;;###autoload
(defun eservo-keys (keys)
  "Send KEYS to the page: tokens like \"RET\", \"TAB\" or plain text."
  (interactive "Meservo keys: ")
  (eservo-backend-call (eservo--driver-or-error) 'keys keys))

;;;###autoload
(defun eservo-wait (spec)
  "Wait for SPEC: seconds (number) or a CSS selector to appear.
A minibuffer input like \"3\" or \"0.5\" becomes a number."
  (interactive "Meservo wait (seconds or CSS selector): ")
  (setq spec (eservo--maybe-number spec))
  (eservo-backend-call (eservo--driver-or-error) 'wait spec))

;;;###autoload
(defun eservo-extract (selector)
  "Return the text of all elements matching SELECTOR, and show it."
  (interactive "Meservo extract selector: ")
  (let ((text (eservo-backend-call (eservo--driver-or-error)
                                   'extract selector)))
    (eservo--show "extract" text)
    text))

;;;###autoload
(defun eservo-screenshot (file)
  "Best-effort PNG screenshot of the page to FILE."
  (interactive "Feservo screenshot to file: ")
  (prog1 (eservo-backend-call (eservo--driver-or-error) 'screenshot file)
    (message "eservo: screenshot saved to %s" file)))

(defun eservo--maybe-number (s)
  "Return S as a number when it looks numeric, else S unchanged.
Numbers (already converted by a script) pass through untouched."
  (cond ((numberp s) s)
        ((and (stringp s) (string-match-p "\\`[0-9.]+\\'" s))
         (string-to-number s))
        (t s)))

(defun eservo--show (name text)
  "Show TEXT in a read-only buffer *eservo-NAME* (for TTY eyeballs)."
  (let ((buf (get-buffer-create (concat "*eservo-" name "*"))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text "\n"))
      (goto-char (point-min))
      (special-mode))
    (pop-to-buffer buf)))

;;;###autoload
(defun eservo-agent-brief ()
  "Print the eservo tool menu plus the current page snapshot.
This is THE entry point for an LLM agent: everything it can do is
listed with the exact command names, followed by the live snapshot
so it can pick [N] refs for `eservo-click'.  The text is also put on
the kill-ring (handy from `emacs -nw' where an agent scrapes the
clipboard or the *eservo-agent-brief* buffer)."
  (interactive)
  (let* ((running (and eservo--current-driver
                       (eservo-backend-call eservo--current-driver
                                            'alive-p)))
         (menu
          (concat
           "eservo agent brief\n"
           "==================\n\n"
           "Backend: " (if eservo--current-driver
                           (format "%s (%s)"
                                   (eservo-backend-name
                                    (eservo--driver-backend
                                     eservo--current-driver))
                                   (if running "running" "stopped"))
                         "none (call eservo-start)\n")
           "URL: " (if running (eservo-url) "-") "\n\n"
           "Tools (all M-x callable; backend ops also usable from\n"
           "eservo-script-run scripts, see eservo-scripts/):\n"
           "  eservo-start          -- start the browser (backend cdp|adb)\n"
           "  eservo-goto URL       -- navigate\n"
           "  eservo-snapshot       -- DOM outline with [N] element refs\n"
           "  eservo-fill SEL TEXT  -- set an input's value (React-safe)\n"
           "  eservo-click REF      -- click by [N] ref or CSS selector\n"
           "  eservo-keys KEYS      -- key tokens (RET TAB ESC ...) or text\n"
           "  eservo-wait N|SEL     -- wait seconds or for a selector\n"
           "  eservo-extract SEL    -- text of all elements matching SEL\n"
           "  eservo-screenshot F   -- PNG screenshot (best effort)\n"
           "  eservo-agent-brief    -- this menu + fresh snapshot\n"
           "  eservo-stop           -- stop the browser\n"
           "Sessions: eservo-session-save SITE / eservo-session-load SITE\n"
           "Scripts:  eservo-script-run FILE (deterministic, no AI)\n\n"
           "Current snapshot:\n"))
         (snap (if running
                   (eservo-backend-call eservo--current-driver 'snapshot)
                 "  (no browser running -- run eservo-start)"))
         (text (concat menu snap)))
    (eservo--show "agent-brief" text)
    (kill-new text)
    text))

(provide 'eservo)
;;; eservo.el ends here
