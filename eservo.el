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
;;   M-x eservo-start  M-x eservo-goto  M-x eservo-snapshot
;;   ... read refs [N] ... M-x eservo-click / eservo-fill ... repeat.

;;; Code:

(require 'cl-lib)
(require 'eservo-backend)

(defgroup eservo nil
  "Drive a web browser from Emacs (Linux/TTY/Android)."
  :prefix "eservo-"
  :group 'applications)

(defcustom eservo-backend 'cdp
  "Default backend used by `eservo-start'.
`cdp' drives Chromium/Chrome via the DevTools Protocol; `adb' drives
an Android device browser over `adb shell' (best effort)."
  :group 'eservo
  :type '(choice (const :tag "Chromium/Chrome via CDP" cdp)
                 (const :tag "Android device via adb" adb)
                 (symbol :tag "Other registered backend")))

(defvar eservo--current-driver nil
  "The one live browser-driving session, or nil.
Set by `eservo-start', cleared by `eservo-stop'.")

(defun eservo--driver-or-error ()
  "Return `eservo--current-driver', erroring with a helpful hint."
  (or eservo--current-driver
      (error "eservo: no browser started (run eservo-start)")))

(defun eservo--backend-symbol ()
  "Backend symbol chosen by \\[universal-argument] or `eservo-backend'."
  (if current-prefix-arg
      (intern (completing-read "eservo backend: "
                               (mapcar #'car (eservo-backend-registered))
                               nil t))
    eservo-backend))

(defun eservo-start (&optional backend)
  "Start a browser session via BACKEND (default `eservo-backend').
With \\[universal-argument] prompt for the backend.
Returns the driver.  Errors with a hint if one is already live."
  (interactive (list (eservo--backend-symbol)))
  (when (and eservo--current-driver
             (eservo-backend-call eservo--current-driver 'alive-p))
    (error "eservo: browser already started (run eservo-stop first)"))
  (let* ((backend-name (or backend eservo-backend))
         (driver (eservo--driver-make
                  :backend (eservo-backend-make backend-name)
                  :name (symbol-name backend-name))))
    (eservo-backend-call driver 'start)
    (setq eservo--current-driver driver)
    (message "eservo: %s backend started at %s"
             backend-name (eservo-backend-call driver 'url))
    driver))

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

(defun eservo-goto (url)
  "Navigate the current browser to URL."
  (interactive "Meservo goto URL: ")
  (eservo-backend-call (eservo--driver-or-error) 'goto url))

(defun eservo-snapshot ()
  "Return a compact DOM outline with [N] element refs, and show it.
The refs are what `eservo-click' targets; agents read this text."
  (interactive)
  (let ((snap (eservo-backend-call (eservo--driver-or-error) 'snapshot)))
    (eservo--show "snapshot" snap)
    snap))

(defun eservo-fill (selector text)
  "Set SELECTOR's value to TEXT (React/Vue-safe input events)."
  (interactive "Meservo fill selector: \nMeservo fill text: ")
  (prog1 (eservo-backend-call (eservo--driver-or-error) 'fill selector text)
    (message "eservo: filled %s" selector)))

(defun eservo-click (ref)
  "Click element REF: a number from `eservo-snapshot' or a CSS selector."
  (interactive "Meservo click (ref number or CSS selector): ")
  (setq ref (eservo--maybe-number ref))
  (prog1 (eservo-backend-call (eservo--driver-or-error) 'click ref)
    (message "eservo: clicked %s" ref)))

(defun eservo-keys (keys)
  "Send KEYS to the page: tokens like \"RET\", \"TAB\" or plain text."
  (interactive "Meservo keys: ")
  (eservo-backend-call (eservo--driver-or-error) 'keys keys))

(defun eservo-wait (spec)
  "Wait for SPEC: seconds (number) or a CSS selector to appear.
A minibuffer input like \"3\" or \"0.5\" becomes a number."
  (interactive "Meservo wait (seconds or CSS selector): ")
  (setq spec (eservo--maybe-number spec))
  (eservo-backend-call (eservo--driver-or-error) 'wait spec))

(defun eservo-extract (selector)
  "Return the text of all elements matching SELECTOR, and show it."
  (interactive "Meservo extract selector: ")
  (let ((text (eservo-backend-call (eservo--driver-or-error)
                                   'extract selector)))
    (eservo--show "extract" text)
    text))

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
