;;; test-helpers.el --- shared test doubles for eservo tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Fake servers, all written in Elisp and running inside the test
;; Emacs process, so tests need NO external programs (no chrome, no
;; node, no python).  Everything here listens on an ephemeral localhost
;; port picked by the OS.

;;; Code:

(require 'eservo-ws)

;;;; ---------- Fake HTTP server ----------

(defun eservo-test--http-response (body)
  "Wrap BODY in a minimal HTTP/1.1 response string (nil body = 404)."
  (if body
      (format "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
              (string-bytes (encode-coding-string body 'utf-8)) body)
    "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"))

(defun eservo-test--http-server (handler)
  "Run a tiny HTTP server; return its port.
HANDLER is called as (HANDLER METHOD PATH) and must return the
response body as a string (nil = 404).  Only the request line is
parsed; the connection is closed after one response, which is enough
for url.el synchronous GETs used by the CDP backend."
  (let ((srv (make-network-process
              :name "eservo-test-http" :server t :host 'local :service t
              :coding 'no-conversion :filter-multibyte nil
              :filter (lambda (proc string)
                        (let ((buf (concat (process-get proc 'buf) string)))
                          (process-put proc 'buf buf)
                          (when (string-search "\r\n\r\n" buf)
                            (let* ((parts (split-string
                                           (car (split-string buf "\r\n")) " "))
                                   (body (funcall handler
                                                  (nth 0 parts) (nth 1 parts))))
                              (process-send-string proc
                                                   (eservo-test--http-response body))
                              (delete-process proc))))))))
    (process-contact srv :service)))

;;;; ---------- Fake WebSocket server (handshake + echo/RPC) ----------

;; A fake WS server that finishes the RFC 6455 handshake, unmasks
;; client frames, and forwards every text message to HANDLER as
;; (HANDLER CONN TEXT).  CONN is a plist; reply with
;; `eservo-test--ws-server-send'.

(defun eservo-test--ws-server (handler)
  "Start a fake WebSocket server; return its port.
HANDLER is called as (HANDLER CONN TEXT) for every complete client
text frame; CONN is a plist with :proc, :buf, :hs, :frames and
:handler keys.  Reply via `eservo-test--ws-server-send'.  Only one
client connection at a time is supported (enough for tests)."
  (let ((srv (make-network-process
              :name "eservo-test-ws" :server t :host 'local :service t
              :coding 'no-conversion :filter-multibyte nil
              :filter (lambda (proc string)
                        (let ((conn (process-get proc 'eservo-test-conn)))
                          (unless conn
                            (setq conn (list :proc proc :buf "" :hs nil
                                             :frames nil :handler handler)))
                          (process-put proc 'eservo-test-conn conn)
                          (eservo-test--ws-conn-filter proc string)))
              :sentinel (lambda (proc _event)
                          (process-put proc 'eservo-test-conn nil)))))
    (process-contact srv :service)))

(defun eservo-test--ws-conn-filter (proc string)
  "Fake-WS server side filter: handshake, then frame parsing."
  (let* ((conn (process-get proc 'eservo-test-conn))
         (buf (concat (plist-get conn :buf) (string-to-unibyte string))))
    (if (not (plist-get conn :hs))
        ;; Handshake: read until end of headers, compute accept key.
        (let ((idx (string-search "\r\n\r\n" buf)))
          (when idx
            (let* ((head (decode-coding-string (substring buf 0 idx) 'us-ascii))
                   (key (when (string-match "Sec-WebSocket-Key: \\([^\r\n]*\\)" head)
                          (match-string 1 head)))
                   (left (substring buf (+ idx 4))))
              (process-send-string
               proc (format (concat "HTTP/1.1 101 Switching Protocols\r\n"
                                    "Upgrade: websocket\r\n"
                                    "Connection: Upgrade\r\n"
                                    "Sec-WebSocket-Accept: %s\r\n\r\n")
                            (eservo-ws--accept-key key)))
              (plist-put conn :buf left)
              (plist-put conn :hs t)
              ;; Let the handler fire at connect time (TEXT is nil).
              (funcall (plist-get conn :handler) conn nil)
              (eservo-test--ws-conn-filter proc ""))))
      ;; Frames after handshake.
      (let* ((split (eservo-ws--read-frames buf)))
        (plist-put conn :buf (cdr split))
        (dolist (frame (car split))
          (pcase-let* ((`(,opcode _fin ,maskkey ,payload) frame))
            (when maskkey (setq payload (eservo-ws--unmask maskkey payload)))
            ;; Record every frame for assertions.
            (plist-put conn :frames
                       (cons (list opcode (decode-coding-string payload 'utf-8))
                             (plist-get conn :frames)))
            (pcase opcode
              (1 (funcall (plist-get conn :handler) conn
                          (decode-coding-string payload 'utf-8)))
              (8 (delete-process proc))
              (9 (process-send-string
                  proc (eservo-ws--frame payload 10))))))))))

(defun eservo-test--ws-server-send (conn text)
  "Send TEXT (server -> client, unmasked) over fake-WS CONN."
  (process-send-string (plist-get conn :proc)
                       (eservo-ws--frame (encode-coding-string text 'utf-8)
                                         eservo-ws-op-text)))

;;;; ---------- Fake DevTools (CDP) endpoint ----------

(defun eservo-test--cdp-server (&optional replies)
  "Start a fake Chrome DevTools endpoint (HTTP /json + WS JSON-RPC).
REPLIES is an alist (METHOD-STRING . RESULT-OBJECT); when a request's
method has no entry, RESULT is ((status . \"ok\")).  Return the fake
state as a plist: (:http HTTP-PORT :ws WS-PORT :requests LIST
:replies REPLIES).  :requests is mutated in place (newest first), so
tests can read it after a run."
  (let* ((fake (list :requests nil :calls nil :replies replies))
         (handler
          (lambda (conn text)
            (when text
              (let* ((msg (json-parse-string text
                                             :object-type 'alist
                                             :array-type 'list
                                             :null-object nil
                                             :false-object nil))
                     (id (cdr (assoc 'id msg)))
                     (method (cdr (assoc 'method msg)))
                     (params (cdr (assoc 'params msg))))
                ;; Record method (and params) for later assertions.
                (plist-put fake :requests
                           (cons method (plist-get fake :requests)))
                (plist-put fake :calls
                           (cons (cons method params)
                                 (plist-get fake :calls)))
                (let ((result (or (cdr (assoc method
                                              (plist-get fake :replies)))
                                  '((status . "ok")))))
                  (eservo-test--ws-server-send
                   ;; json-encode (not json-serialize): the C serializer
                   ;; chokes on alists nested inside arrays (e.g. a
                   ;; list of cookie objects) -- see AI-REVIEW.org.
                   conn (json-encode `((id . ,id) (result . ,result)))))))))
         (ws-port (eservo-test--ws-server handler))
         (http-port (eservo-test--http-server
                     (lambda (_method path)
                       (if (string= path "/json")
                           (format
                            "[{\"id\":\"page1\",\"type\":\"page\",\"title\":\"Test\",\"url\":\"about:blank\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:%s/devtools/page/1\"}]"
                            ws-port)
                         (error "fake cdp: unexpected path %s" path)))))
         )
    (plist-put fake :http http-port)
    (plist-put fake :ws ws-port)
    fake))

(provide 'test-helpers)
;;; test-helpers.el ends here
