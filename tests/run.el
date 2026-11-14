;;; run.el --- eservo test runner -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Usage:  emacs --batch -l tests/run.el
;; Exits 0 when all tests pass, 1 otherwise (ert-run-tests-batch-and-exit).

;;; Code:

(require 'ert)

(defvar eservo-test--root
  (file-name-as-directory
   (file-name-directory (directory-file-name (file-name-directory load-file-name))))
  "Root directory of the eservo source tree.")

;; Package sources first, then tests (so tests can require the package
;; files by name).
(add-to-list 'load-path eservo-test--root)
(add-to-list 'load-path (expand-file-name "tests" eservo-test--root))

;; Shared test helpers must be loaded before any test file uses them.
(load "test-helpers" nil t)

;; Every tests/test-*.el file is a test suite; load them all.
(dolist (file (directory-files (expand-file-name "tests" eservo-test--root)
                               t "test-.*\\.el\\'"))
  (load (file-name-sans-extension file) nil t))

(ert-run-tests-batch-and-exit t)

;;; run.el ends here
