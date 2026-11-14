;;; eservo-rdp.el --- Firefox Remote Debugging Protocol client for eservo -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of eservo.  See the header of eservo.el for details.

;;; Commentary:

;; A tiny synchronous client for the Remote Debugging Protocol (RDP)
;; that Firefox DevTools speak -- the protocol Servo's devtools server
;; implements when started with `--devtools=PORT'.
;;
;; Transport: plain TCP.  Packets are JSON documents framed as
;;
;;     <byte-length>:<JSON>
;;
;; (the framing Firefox RDP has always used).  Several packets may
;; arrive in one chunk and one packet may split across chunks, so the
;; process filter only accumulates bytes; parsing happens on demand.
;;
;; Handshake (shapes taken from a real servo devtools session log):
;;   1. the server pushes the root hello right after connect:
;;        {"from":"root","applicationType":"browser","traits":{...}}
;;   2. Firefox sends {"type":"connect","frontendVersion":...,"to":"root"};
;;      we send the same but do NOT wait for its reply (servo may or
;;      may not answer it; the hello already proved the wire works).
;;   3. {"to":"root","type":"listTabs"} -> {"from":"root","tabs":[...]}
;;
;; Replies are matched by their `from' actor only -- RDP carries no
;; request id -- so the client keeps ONE outstanding request per
;; actor, like the Firefox client does.  Unsolicited packets
;; (notifications such as tabListChanged, console messages) are kept
;; in a bounded queue and silently dropped when it overflows; they
;; never confuse a pending request because requests can name the
;; field they expect (`match' predicate).

;;; Code:

(require 'cl-lib)
(require 'json)

(defgroup eservo-rdp nil
  "Firefox RDP transport for eservo (used by the servo backend)."
  :group 'eservo)

(defcustom eservo-rdp-timeout 30
  "Seconds to wait for one RDP reply."
  :group 'eservo-rdp
  :type 'number)

(defconst eservo-rdp--queue-max 100
  "Unmatched packets kept per connection before old ones are dropped.")

(cl-defstruct (eservo-rdp-conn
               (:constructor eservo-rdp-conn--make)
               ;; Accessors eservo-rdp--proc / --buf / --replies / --fail
               ;; (not the default eservo-rdp-conn-PROC: shorter at
               ;; call sites, and consistent with the file's prefix).
               (:conc-name eservo-rdp--))
  "One RDP connection (process + accumulated bytes + reply queue)."
  proc                       ; network process to the server
  (buf nil)                  ; accumulation buffer for split packets
  (replies nil)              ; alists received but not yet consumed
  (fail nil))                ; sentinel error string, set on process death

(defun eservo-rdp--filter (conn _proc data)
  "Process filter: append DATA, parse what is now complete."
  (let ((conn-buf (eservo-rdp--buf conn)))
    ;; The accumulation buffer may have been killed by a previous
    ;; error; recreating it keeps the filter total.
    (unless (buffer-live-p conn-buf)
      (setf (eservo-rdp--buf conn) (generate-new-buffer " *eservo-rdp*")))
    (with-current-buffer (eservo-rdp--buf conn)
      (goto-char (point-max))
      (insert data))
    (eservo-rdp--parse conn)
    (eservo-rdp--trim conn)))

(defun eservo-rdp--sentinel (conn _proc event)
  "Process sentinel: record the failure, wake any waiter.
We use synchronous connects, so the only legitimate sentinel is the
one we cause ourselves by closing; every other status change means
the server went away (exit, crash, connection broken by peer)."
  (when (and event (not (string= event "")))
    (setf (eservo-rdp--fail conn) (string-trim event))))

(defun eservo-rdp--parse (conn)
  "Move every complete packet from the accumulation buffer to the queue.
Packet: <digits>:<that many bytes of JSON>.  Called after every chunk."
  (let ((buf (eservo-rdp--buf conn)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (goto-char (point-min))
        ;; Keep consuming while a full header + body is present.
        (while (looking-at "\\([0-9]+\\):")
          (let* ((len (string-to-number (match-string 1)))
                 (body-start (1+ (match-end 1)))  ; skip the colon
                 (body-end (+ body-start len)))
            (if (< (point-max) body-end)
                ;; Not all bytes arrived yet: leave them for the next
                ;; chunk and stop (point stays at point-min).
                (goto-char (point-max))
              (let* ((body (buffer-substring-no-properties body-start
                                                            body-end))
                     (obj (condition-case nil
                              (json-parse-string
                               body :object-type 'alist :array-type 'list
                               :null-object nil :false-object nil)
                            (error nil))))
                (delete-region (point-min) body-end)
                (when obj (push obj (eservo-rdp--replies conn)))
                (goto-char (point-min))))))))))

(defun eservo-rdp--trim (conn)
  "Bound the unmatched-packet queue."
  (when (> (length (eservo-rdp--replies conn)) eservo-rdp--queue-max)
    (setf (eservo-rdp--replies conn)
          (seq-take (eservo-rdp--replies conn) eservo-rdp--queue-max))))

(defun eservo-rdp-alive-p (conn)
  "Non-nil when CONN's process is live and has not failed."
  (and conn (not (eservo-rdp--fail conn))
       (process-live-p (eservo-rdp--proc conn))))

(defun eservo-rdp--send (conn obj)
  "Encode OBJ as JSON, frame it, send it down the wire."
  (unless (eservo-rdp-alive-p conn)
    (error "eservo-rdp: connection is down (%s)"
           (or (eservo-rdp--fail conn) "process gone")))
  (let* ((json (json-encode obj))
         ;; Length counts BYTES; our payloads are ASCII, but be exact.
         (payload (format "%d:%s" (string-bytes json) json)))
    (process-send-string (eservo-rdp--proc conn) payload)))

(defun eservo-rdp--take-reply (conn actor match)
  "Dequeue the first reply from ACTOR satisfying MATCH (or any)."
  (let ((rest (eservo-rdp--replies conn))
        (found nil)
        (keep '()))
    (dolist (r rest)
      (if (and (not found)
               (equal (cdr (assq 'from r)) actor)
               (or (null match) (funcall match r)))
          (setq found r)
        (push r keep)))
    (setf (eservo-rdp--replies conn) (nreverse keep))
    found))

(defun eservo-rdp-wait-reply (conn actor &optional match)
  "Wait for a reply from ACTOR satisfying MATCH; return the alist.
MATCH is a predicate on the reply alist -- use it to skip unrelated
packets from the same actor (notifications, connect echoes)."
  (let ((deadline (+ (float-time) eservo-rdp-timeout)))
    (cl-block wait
      (while t
        (let ((reply (eservo-rdp--take-reply conn actor match)))
          (when reply (cl-return-from wait reply)))
        (when (eservo-rdp--fail conn)
          (error "eservo-rdp: connection died: %s"
                 (eservo-rdp--fail conn)))
        (when (>= (float-time) deadline)
          (error "eservo-rdp: timed out waiting for a reply from `%s'"
                 actor))
        ;; Wake on incoming bytes, then re-scan the queue.
        (accept-process-output (eservo-rdp--proc conn) 0.2)))))

(defun eservo-rdp-request (conn actor type &optional fields match)
  "Send {to:ACTOR, type:TYPE, ...FIELDS}; wait for and return the reply.
MATCH is passed to `eservo-rdp-wait-reply'.  One request per actor at
a time -- RDP has no request ids, so ordering is the only address."
  (eservo-rdp--send conn `((to . ,actor) (type . ,type)
                           ,@(or fields ())))
  (eservo-rdp-wait-reply conn actor match))

(defun eservo-rdp-open (host port)
  "Connect to an RDP server at HOST:PORT and run the handshake.
Returns the connection after the root hello arrives.  The Firefox
`connect' greeting is sent fire-and-forget (see Commentary)."
  (let* ((conn (eservo-rdp-conn--make))
         (buf (generate-new-buffer " *eservo-rdp*"))
         (proc (make-network-process
                :name "eservo-rdp"
                :buffer buf
                :host host
                :service port
                :nowait nil)))
    (setf (eservo-rdp--buf conn) buf
          (eservo-rdp--proc conn) proc)
    (set-process-filter proc (lambda (p d) (eservo-rdp--filter conn p d)))
    (set-process-sentinel proc (lambda (p e) (eservo-rdp--sentinel conn p e)))
    ;; The hello: the first packet the server pushes on connect.
    (eservo-rdp-wait-reply conn "root"
                           (lambda (r) (assq 'applicationType r)))
    ;; Greet like Firefox does; do not require an answer.
    (eservo-rdp--send conn '((to . "root") (type . "connect")
                             (frontendVersion . "eservo")))
    conn))

(defun eservo-rdp-close (conn)
  "Close CONN and its buffers.  Harmless if already dead."
  (when conn
    (ignore-errors (delete-process (eservo-rdp--proc conn)))
    (when (buffer-live-p (eservo-rdp--buf conn))
      (kill-buffer (eservo-rdp--buf conn)))
    nil))

(provide 'eservo-rdp)
;;; eservo-rdp.el ends here
