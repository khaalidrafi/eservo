;;; eservo-script.el --- deterministic task scripts for eservo -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of eservo.  See the header of eservo.el for details.

;;; Commentary:

;; Run a deterministic task script WITHOUT any AI:
;;
;;   M-x eservo-script-run RET ~/tasks/qwen-ask.el
;;
;; A script is either ONE sexp list of steps or an Org/plain file with
;; one step per line (comments and headings are skipped):
;;
;;   ((goto "https://chat.qwen.ai")
;;    (wait 3)
;;    (fill "textarea" "hello")
;;    (keys "RET")
;;    (wait 5)
;;    (extract ".answer")
;;    (write "out.txt"))
;;
;; Org flavour (same steps, one per line):
;;   * Ask qwen
;;   - (session-load "chat.qwen.ai")
;;   - (goto "https://chat.qwen.ai")
;;   - (fill "textarea" "hello") ...
;;
;; Steps: goto/wait/sleep/fill/fill-secret/click/keys/extract/
;; screenshot/session-load/write/echo/stop.  `(fill-secret SELECTOR
;; SITE)' types the password from `auth-source' (never in the script,
;; never on screen).  Every step result is collected and returned, so
;; Elisp callers can post-process; each result is also messaged.
;;
;; NOTE: scripts run as YOUR Emacs user with YOUR credentials -- only
;; run scripts you have read.  There is no sandboxing (v0.1 keeps it
;; simple; see AI-REVIEW.org).

;;; Code:

(require 'eservo)
(require 'eservo-backend)
(require 'eservo-session)

(defun eservo-script--parse (file)
  "Parse FILE into a list of steps.
A file whose first non-space char is \"(\" is read as sexps: either
one list of steps or one top-level step per sexp.  Any other file is
treated as Org/plain text: one sexp step per line, skipping headings,
bullets and comments."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    ;; A .el-style script opens with `;' header comments; skip those
    ;; (and blank lines) before deciding which flavour this file is,
    ;; so a commented header does not push a sexp script into the
    ;; line-by-line Org parser (where its multi-line sexp would hit
    ;; an unbalanced-paren read error).
    (while (and (not (eobp))
                (or (looking-at "[ \t]*$")  ; blank line
                    (looking-at "[ \t]*;"))) ; comment line
      (forward-line 1))
    (if (looking-at "[ \t\n\r]*(")
        ;; ---- sexp form ----
        (let ((forms '()))
          (condition-case _e
              (while t (push (read (current-buffer)) forms))
            (end-of-file))
          (setq forms (nreverse forms))
          ;; A single form that is itself a list-of-steps (its car is a
          ;; list, e.g. ((goto ...) (wait ...)) unwraps to the steps.
          (if (and (= (length forms) 1)
                   (consp (car forms))
                   (consp (car (car forms))))
              (car forms)
            forms))
      ;; ---- Org / plain form ----
      (let ((steps '()))
        (while (not (eobp))
          (let ((line (string-trim
                       (buffer-substring-no-properties
                        (line-beginning-position)
                        (line-end-position)))))
            ;; Strip Org bullets / leading markup.
            (setq line (replace-regexp-in-string "\\`[-+*]+[ \t]*" "" line))
            (when (and (string-prefix-p "(" line)
                       (not (string-prefix-p ";;" line)))
              (push (read line) steps)))
          (forward-line 1))
        (nreverse steps)))))

(defun eservo-script-run (file)
  "Execute the deterministic eservo script FILE (no AI involved).
Starts the default backend if no browser is running.  Returns an
alist of (OP . RESULT) in step order.  The browser is left running;
add a (stop) step or run `eservo-stop' to close it."
  (interactive "feservo script to run: ")
  (let ((steps (eservo-script--parse file))
        (results '())
        (last-extract nil))
    (unless eservo--current-driver
      (eservo-start))
    (message "eservo-script: running %s (%d steps)" file (length steps))
    (dolist (step steps)
      (let* ((op (car step))
             (val (pcase step
                    (`(goto ,url) (eservo-goto url))
                    (`(wait ,spec) (eservo-wait spec))
                    (`(sleep ,secs) (sit-for secs))
                    (`(fill ,sel ,text) (eservo-fill sel text))
                    ;; The secret never appears in the script file,
                    ;; the step log or the echo area.
                    (`(fill-secret ,sel ,site)
                     (eservo-fill sel (cdr (eservo-credentials site))))
                    (`(click ,ref) (eservo-click ref))
                    (`(keys ,keys) (eservo-keys keys))
                    (`(extract ,sel) (eservo-extract sel))
                    (`(screenshot ,f) (eservo-screenshot f))
                    (`(session-load ,site) (eservo-session-load site))
                    (`(stop) (eservo-stop))
                    (`(write ,outfile)
                     (unless (stringp last-extract)
                       (error
                        "eservo-script: `write' needs a previous `extract' step"))
                     (with-temp-file outfile (insert last-extract))
                     outfile)
                    (`(echo ,text) (message "eservo-script: %s" text)
                     text)
                    (_ (error "eservo-script: unknown step %S" step)))))
        (when (eq op 'extract)
          (setq last-extract val))
        ;; Log only the op name: step arguments could contain user
        ;; content, and we never want to grow into a secret-leaker.
        (message "eservo-script: done %s" op)
        (push (cons op val) results)))
    (message "eservo-script: finished %s (%d steps)"
             (file-name-nondirectory file) (length steps))
    (nreverse results)))

(provide 'eservo-script)
;;; eservo-script.el ends here
