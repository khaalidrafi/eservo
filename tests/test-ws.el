;;; test-ws.el --- tests for eservo-ws.el -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eservo-ws)
(require 'test-helpers)

(defmacro eservo-test--with-fake-ws (var &rest body)
  "Start a fake WS echo server, bind VAR to its port, run BODY."
  `(let ((,var (eservo-test--ws-server
                (lambda (conn text)
                  ;; Echo server: reply with the same text (skip the
                  ;; connect-time callback where TEXT is nil).
                  (when text
                    (eservo-test--ws-server-send conn text))))))
     ,@body))

(ert-deftest eservo-ws-accept-key-test-vector ()
  "RFC 6455 §1.3 example handshake must be reproduced exactly."
  (should (string= (eservo-ws--accept-key "dGhlIHNhbXBsZSBub25jZQ==")
                   "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")))

(ert-deftest eservo-ws-frame-roundtrip-small ()
  "A short text frame must survive encode->parse."
  (let* ((bytes (eservo-ws--frame (string-to-unibyte "hello") 1 'client))
         (split (eservo-ws--read-frames bytes)))
    (should (= (length (cdr split)) 0)) ; everything consumed
    (pcase-let ((`((,opcode ,fin ,maskkey ,payload)) (car split)))
      (should (= opcode eservo-ws-op-text))
      (should fin)
      (should maskkey)                  ; client frames are masked
      (should (string= (decode-coding-string
                        (eservo-ws--unmask maskkey payload) 'utf-8)
                       "hello")))))

(ert-deftest eservo-ws-frame-roundtrip-extended-lengths ()
  "Frames at the 126- and 127-length boundaries must round-trip."
  ;; 200 bytes -> 2-byte extended length.
  (let* ((payload200 (make-string 200 ?x))
         (split (eservo-ws--read-frames
                 (eservo-ws--frame (string-to-unibyte payload200) 1 nil))))
    (pcase-let ((`((,opcode _fin _mask ,payload)) (car split)))
      (should (= opcode eservo-ws-op-text))
      (should (string= payload payload200))))
  ;; 70000 bytes -> 8-byte extended length.
  (let* ((payload70k (make-string 70000 ?y))
         (split (eservo-ws--read-frames
                 (eservo-ws--frame (string-to-unibyte payload70k) 1 nil))))
    (pcase-let ((`((_ _ _ ,payload)) (car split)))
      (should (string= payload payload70k)))))

(ert-deftest eservo-ws-read-frames-keeps-incomplete-tail ()
  "A partial frame must be returned as REST, not lost."
  (let* ((bytes (eservo-ws--frame (string-to-unibyte "hello world") 1 nil))
         ;; Chop the last 3 bytes off.
         (chopped (substring bytes 0 (- (length bytes) 3)))
         (split (eservo-ws--read-frames chopped)))
    (should (null (car split)))         ; no complete frame yet
    (should (equal (cdr split) chopped))
    ;; After feeding the missing bytes, the frame completes.
    (let ((split2 (eservo-ws--read-frames
                   (concat (cdr split) (substring bytes (- (length bytes) 3))))))
      (pcase-let ((`((_ _ _ ,payload)) (car split2)))
        (should (string= payload "hello world"))))))

(ert-deftest eservo-ws-utf8-payload-roundtrip ()
  "Non-ASCII payloads survive the UTF-8 encode/decode layer."
  (let* ((text "héllo wörld ✓")
         (split (eservo-ws--read-frames
                 (eservo-ws--frame (encode-coding-string text 'utf-8) 1 nil))))
    (pcase-let ((`((_ _ _ ,payload)) (car split)))
      (should (string= (decode-coding-string payload 'utf-8) text)))))

(ert-deftest eservo-ws-connect-send-receive ()
  "End-to-end: client connects, sends, echo server replies."
  (eservo-test--with-fake-ws port
    (let* ((got nil)
           (ws (eservo-ws-connect "127.0.0.1" port "/" (lambda (_ws text)
                                                         (push text got)))))
      (eservo-ws-send ws "hello eservo")
      ;; Pump the event loop until the echo arrives (max 5s).
      (let ((deadline (+ (float-time) 5)))
        (while (and (null got) (< (float-time) deadline))
          (accept-process-output nil 0.1)))
      (should (equal got '("hello eservo")))
      (eservo-ws-close ws)
      (should (eservo-ws-closed ws)))))

(ert-deftest eservo-ws-fragmented-message ()
  "Server-side fragmentation must be reassembled before delivery."
  (let* ((got nil)
         (ws nil))
    ;; Fake server that splits its reply into two fragments (once).
    (let ((port (eservo-test--ws-server
                 (lambda (conn _text)
                   (unless (plist-get conn :sent-frags)
                     (plist-put conn :sent-frags t)
                     ;; Two frames: continuation opcode 0 for part 2.
                     (process-send-string
                      (plist-get conn :proc)
                      (concat (eservo-ws--frame (string-to-unibyte "frag1")
                                                1 nil 'nonfinal)
                              (eservo-ws--frame (string-to-unibyte "frag2")
                                                0 nil))))))))
      (setq ws (eservo-ws-connect "127.0.0.1" port "/"
                                  (lambda (_ws text) (push text got))))
      (eservo-ws-send ws "please")
      (let ((deadline (+ (float-time) 5)))
        (while (and (null got) (< (float-time) deadline))
          (accept-process-output nil 0.1)))
      (should (equal got '("frag1frag2")))
      (eservo-ws-close ws))))

(ert-deftest eservo-ws-server-ping-gets-pong ()
  "Client must answer a server ping with a pong (seen by the fake server)."
  (let* ((server-conn nil)
         (port (eservo-test--ws-server
                (lambda (conn _text)
                  (setq server-conn conn)
                  ;; Ping once, at connect time only.
                  (unless (plist-get conn :pinged)
                    (plist-put conn :pinged t)
                    (process-send-string
                     (plist-get conn :proc)
                     (eservo-ws--frame (string-to-unibyte "ping!") 9 nil))))))
         (ws (eservo-ws-connect "127.0.0.1" port "/"
                                (lambda (_ws _text) nil))))
    (let ((deadline (+ (float-time) 5)))
      (while (and (or (null server-conn)
                      (null (plist-get server-conn :frames)))
                  (< (float-time) deadline))
        (accept-process-output nil 0.1)))
    ;; The fake server must have recorded our pong (opcode 10).
    (should (member (list 10 "ping!")
                    (plist-get server-conn :frames)))
    ;; And the client stays alive after the ping/pong exchange.
    (should (not (eservo-ws-closed ws)))
    (eservo-ws-close ws)))

(provide 'test-ws)
;;; test-ws.el ends here
