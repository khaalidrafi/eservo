;;; eservo-ws.el --- Minimal pure-Elisp WebSocket client for eservo -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is part of eservo.  See the header of eservo.el for details.

;;; Commentary:

;; A deliberately small RFC 6455 subset client, written in pure Elisp so
;; that eservo has NO external package dependencies and runs anywhere
;; Emacs runs (Linux desktop, TTY, Android/Termux).
;;
;; Supported: text frames, fragmentation (continuation frames), masking
;; (client->server), ping/pong, close.  Not supported: binary extensions,
;; permessage-deflate (we simply never negotiate it), TLS wss://.
;;
;; CDP (Chrome DevTools Protocol) speaks JSON over WebSocket text
;; frames, which is exactly this subset.  Design goal: small enough to
;; review in one sitting.  If it ever grows past ~250 lines, replace it
;; with the `websocket' package instead (see AI-REVIEW.org).

;;; Code:

(require 'cl-lib)

(defgroup eservo-ws nil
  "Minimal WebSocket client used by eservo backends."
  :group 'eservo)

(defconst eservo-ws--guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  "Magic GUID from RFC 6455 §1.3 used to compute Sec-WebSocket-Accept.")

;; Protocol opcodes we care about (RFC 6455 §5.2).
(defconst eservo-ws-op-text 1)
(defconst eservo-ws-op-close 8)
(defconst eservo-ws-op-ping 9)
(defconst eservo-ws-op-pong 10)

(cl-defstruct (eservo-ws (:constructor eservo-ws--new))
  "State of one WebSocket client connection."
  proc           ; network process of the TCP connection
  buf            ; raw bytes received but not yet parsed (unibyte string)
  handshake-done ; t once the HTTP 101 handshake has been read
  fragment       ; accumulated payload of an ongoing fragmented message
  cb             ; function called as (CB WS TEXT) per complete text message
  closed)        ; t once the connection is closed (by us or the peer)

(defun eservo-ws--accept-key (key)
  "Compute the RFC 6455 Sec-WebSocket-Accept value for request KEY."
  (base64-encode-string
   (secure-hash 'sha1 (concat key eservo-ws--guid) nil nil t) t))

(defun eservo-ws--random-mask ()
  "Return a fresh 4-byte masking key (unibyte string)."
  (unibyte-string (random 256) (random 256) (random 256) (random 256)))

(defun eservo-ws--unmask (mask payload)
  "XOR unibyte PAYLOAD bytes with the 4-byte MASK key, returning unibyte bytes."
  (let ((n (length payload))
        (out (make-string (length payload) 0)))
    (dotimes (i n)
      (aset out i (logxor (aref payload i) (aref mask (mod i 4)))))
    ;; make-string gives a unibyte string only when all chars < 256 are
    ;; set as raw bytes; ensure unibyte representation explicitly.
    (string-to-unibyte out)))

(defun eservo-ws--be (value nbytes)
  "Encode VALUE as NBYTES big-endian bytes in a unibyte string."
  (let ((out (make-string nbytes 0)))
    (dotimes (i nbytes)
      (aset out (- nbytes 1 i)
            (logand (ash value (* -8 i)) #xff)))
    out))

(defun eservo-ws--frame (payload &optional opcode mask fin)
  "Encode one WebSocket frame carrying unibyte PAYLOAD.
OPCODE defaults to 1 (text).  MASK nil means unmasked (server->client);
the symbol `client' means generate a random mask (client->server, which
RFC 6455 requires); a 4-byte string uses that mask (tests).  FIN: pass
the symbol `nonfinal' for a fragmented continuation-expected frame;
everything else is final (FIN=1)."
  (let* ((opcode (or opcode eservo-ws-op-text))
         (finbyte (if (eq fin 'nonfinal) 0 #x80))
         (plen (length payload))
         (maskkey (cond ((eq mask 'client) (eservo-ws--random-mask))
                        (mask mask)
                        (t nil)))
         (body (if maskkey (eservo-ws--unmask maskkey payload) payload))
         ;; First byte: FIN flag + opcode.
         (b0 (logior finbyte opcode))
         ;; Length field: <126 inline, 126 => 2 BE bytes, 127 => 8 BE
         ;; bytes (RFC 6455 §5.2).  MASK bit goes on the first length
         ;; byte when we mask.
         (lenpart
          (cond ((< plen 126)
                 (unibyte-string (if maskkey (logior #x80 plen) plen)))
                ((< plen 65536)
                 (concat (unibyte-string (if maskkey (logior #x80 126) 126))
                         (eservo-ws--be plen 2)))
                (t
                 (concat (unibyte-string (if maskkey (logior #x80 127) 127))
                         (eservo-ws--be plen 8))))))
    (if maskkey
        (concat (unibyte-string b0) lenpart maskkey body)
      (concat (unibyte-string b0) lenpart body))))

(defun eservo-ws--read-frames (buf)
  "Parse complete frames out of unibyte BUF.
Return (FRAMES . REST-BYTES).  Each frame is a list
\(OPCODE FIN MASKKEY PAYLOAD\) where MASKKEY is nil for unmasked frames
and PAYLOAD is still masked when MASKKEY is non-nil (the caller
unmasks).  Incomplete trailing data is returned in REST-BYTES."
  (let ((frames '())
        (pos 0)
        (n (length buf))
        done)
    (while (and (not done) (>= (- n pos) 2))
      (let* ((b0 (aref buf pos))
             (opcode (logand b0 #x0f))
             (fin (/= 0 (logand b0 #x80)))
             (b1 (aref buf (1+ pos)))
             (masked (/= 0 (logand b1 #x80)))
             (len (logand b1 #x7f))
             (hdr 2)
             ;; Make sure the extended-length header (and the mask key)
             ;; are fully present before reading them, else wait for
             ;; more bytes in the next filter run.
             (avail (- n pos)))
        (cond
         ((and (= len 126) (< avail 4)) (setq done t))
         ((and (= len 127) (< avail 10)) (setq done t))
         (t
          (when (= len 126)
            (setq len (+ (* 256 (aref buf (+ pos 2)))
                         (aref buf (+ pos 3)))
                  hdr 4))
          (when (= len 127)
            (setq len 0 hdr 10)
            (dotimes (i 8)
              (setq len (+ (* len 256) (aref buf (+ pos 2 i))))))
          ;; Guard against absurd lengths from corrupt streams.
          (when (> len 104857600)   ; 100 MiB
            (error "eservo-ws: frame too large (%d bytes)" len))
          (let ((end (+ pos hdr (if masked 4 0) len)))
            (if (> end n)           ; incomplete frame: stop, keep bytes
                (setq done t)
              (push (list opcode fin
                          (and masked
                               (substring buf (+ pos hdr) (+ pos hdr 4)))
                          (substring buf (+ pos hdr (if masked 4 0)) end))
                    frames)
              (setq pos end)))))))
    (cons (nreverse frames) (substring buf pos))))

(defun eservo-ws--deliver (ws text)
  "Decode TEXT (possibly raw bytes) as UTF-8 and call the callback of WS."
  (funcall (eservo-ws-cb ws) ws (decode-coding-string text 'utf-8)))

(defun eservo-ws--handle-frames (ws frames)
  "Dispatch parsed FRAMES to WS state machine."
  (dolist (frame frames)
    (pcase-let* ((`(,opcode ,fin ,maskkey ,payload) frame)
                 (payload (if maskkey
                              (eservo-ws--unmask maskkey payload)
                            payload)))
      (pcase opcode
        ;; Text or binary message start: binary is tolerated (still text
        ;; in practice for CDP).
        ((or 1 2)
         (if fin
             (eservo-ws--deliver ws payload)
           (setf (eservo-ws-fragment ws) payload)))
        ;; Continuation of a fragmented message.
        (0
         (setf (eservo-ws-fragment ws)
               (concat (eservo-ws-fragment ws) payload))
         (when fin
           (let ((text (eservo-ws-fragment ws)))
             (setf (eservo-ws-fragment ws) nil)
             (eservo-ws--deliver ws text))))
        ;; Ping: must answer with a masked pong carrying same payload.
        (9 (process-send-string (eservo-ws-proc ws)
                                (eservo-ws--frame payload 10 'client)))
        ;; Pong: nothing to do.
        (10 nil)
        ;; Close: acknowledge by dropping the TCP connection.
        (8
         (setf (eservo-ws-closed ws) t)
         (ignore-errors (delete-process (eservo-ws-proc ws))))))))

(defun eservo-ws--filter (proc string)
  "Process filter for eservo WebSocket connections."
  (let ((ws (process-get proc 'eservo-ws)))
    (when ws
      ;; Process coding is no-conversion: STRING may be multibyte
      ;; carrying raw bytes; normalise to a real byte string.
      (setf (eservo-ws-buf ws)
            (concat (eservo-ws-buf ws) (string-to-unibyte string)))
      (unless (eservo-ws-handshake-done ws)
        (eservo-ws--maybe-finish-handshake ws))
      (when (eservo-ws-handshake-done ws)
        (let* ((split (eservo-ws--read-frames (eservo-ws-buf ws))))
          (setf (eservo-ws-buf ws) (cdr split))
          (eservo-ws--handle-frames ws (car split)))))))

(defun eservo-ws--maybe-finish-handshake (ws)
  "Check WS buffer for the HTTP 101 response and finish the handshake."
  (let ((buf (eservo-ws-buf ws)))
    (when-let* ((idx (string-search "\r\n\r\n" buf)))
      (let* ((head (substring buf 0 idx))
             (head-text (decode-coding-string head 'us-ascii))
             (rest (substring buf (+ idx 4)))
             (accept (eservo-ws--accept-key
                      (eservo-ws-key (eservo-ws-proc ws)))))
        ;; RFC 6455 §4.2: only accept when status is 101 and the accept
        ;; key matches (protects us from misconfigured proxies).
        (unless (string-match-p "HTTP/1.1 101" head-text)
          (error "eservo-ws: handshake refused: %s"
                 (substring head-text 0 (min 120 (length head-text)))))
        (unless (string-match-p
                 (regexp-quote accept) head-text)
          (error "eservo-ws: bad Sec-WebSocket-Accept from server"))
        (setf (eservo-ws-buf ws) rest
              (eservo-ws-handshake-done ws) t)))))

(defun eservo-ws-key (proc)
  "Return the handshake key stored on PROC, or the empty string."
  (or (process-get proc 'eservo-ws-key) ""))

(defun eservo-ws--sentinel (proc _event)
  "Mark the WS attached to PROC as closed when the process dies."
  (let ((ws (process-get proc 'eservo-ws)))
    (when ws (setf (eservo-ws-closed ws) t))))

(defun eservo-ws-connect (host port path cb &optional timeout)
  "Open a WebSocket connection synchronously.
HOST, PORT, PATH describe the ws:// endpoint; CB is called as (CB WS
TEXT) for each complete text message.  TIMEOUT (seconds, default 10)
bounds the HTTP 101 handshake.  Returns the `eservo-ws' object, or
signals an error."
  (let* ((timeout (or timeout 10))
         (key (base64-encode-string
               (unibyte-string (random 256) (random 256)
                               (random 256) (random 256)
                               (random 256) (random 256)
                               (random 256) (random 256)
                               (random 256) (random 256)
                               (random 256) (random 256)
                               (random 256) (random 256)
                               (random 256) (random 256))
               t))
         (proc (open-network-stream
                "eservo-ws" nil host port
                ;; Raw bytes in and out; we handle UTF-8 at the message
                ;; layer instead (RFC 6455 frames are byte-oriented).
                :coding 'no-conversion
                :type 'plain
                :noquery t))
         (ws (eservo-ws--new :proc proc :cb cb :buf "")))
    (set-process-filter proc #'eservo-ws--filter)
    (set-process-sentinel proc #'eservo-ws--sentinel)
    (process-put proc 'eservo-ws ws)
    (process-put proc 'eservo-ws-key key)
    ;; RFC 6455 §4.1 opening handshake (no extensions negotiated, so
    ;; the server must not compress; keeps our parser simple).
    (process-send-string proc
                         (format (concat "GET %s HTTP/1.1\r\n"
                                         "Host: %s:%s\r\n"
                                         "Upgrade: websocket\r\n"
                                         "Connection: Upgrade\r\n"
                                         "Sec-WebSocket-Key: %s\r\n"
                                         "Sec-WebSocket-Version: 13\r\n"
                                         "\r\n")
                                 path host port key))
    (let ((deadline (+ (float-time) timeout)))
      (while (and (not (eservo-ws-handshake-done ws))
                  (< (float-time) deadline))
        (accept-process-output proc 0.2))
      (unless (eservo-ws-handshake-done ws)
        (ignore-errors (delete-process proc))
        (error "eservo-ws: handshake timed out after %ss" timeout)))
    ws))

(defun eservo-ws-send (ws text)
  "Send TEXT over WS as one masked text frame (client frames MUST be masked)."
  (when (eservo-ws-closed ws)
    (error "eservo-ws: connection is closed"))
  (process-send-string (eservo-ws-proc ws)
                       (eservo-ws--frame (encode-coding-string text 'utf-8)
                                         eservo-ws-op-text 'client)))

(defun eservo-ws-close (ws)
  "Politely close WS: send a close frame, then drop the TCP connection."
  (unless (eservo-ws-closed ws)
    (ignore-errors
      (process-send-string (eservo-ws-proc ws)
                           (eservo-ws--frame "" eservo-ws-op-close 'client)))
    (setf (eservo-ws-closed ws) t)
    (ignore-errors (delete-process (eservo-ws-proc ws)))))

(provide 'eservo-ws)
;;; eservo-ws.el ends here
