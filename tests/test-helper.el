;;; test-helper.el --- Shared helpers for bv tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'bv)

(defmacro bv-test-with-workspace (&rest body)
  "Run BODY in an isolated temporary Beads workspace."
  (declare (indent 0) (debug t))
  `(let ((root (make-temp-file "bv-test-" t)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name ".beads" root))
           (let ((default-directory root)
                 (bv-workspace nil)
                 (bv-default-workspace nil)
                 (bv-database-file nil))
             ,@body))
       (delete-directory root t))))

(defun bv-test-json (text)
  "Decode JSON TEXT through the package boundary."
  (bv-json-decode text))

(provide 'test-helper)

;;; test-helper.el ends here
