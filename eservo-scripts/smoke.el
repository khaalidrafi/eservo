;;; smoke.el — smallest useful deterministic script: open a page,
;;; prove we can read it, screenshot it.  Run against any site you are
;;; allowed to touch; example.org is the classic choice.
;;
;; Run:  M-x eservo-script-run RET <this file>
;;
;; Sexp flavour (one list of steps).  The Org flavour is the same
;; steps one per line — see qwen-ask.org.

((goto "https://example.org")
 (wait 2)
 (extract "h1")
 (write "/tmp/eservo-smoke.txt")
 (screenshot "/tmp/eservo-smoke.png")
 (stop))
