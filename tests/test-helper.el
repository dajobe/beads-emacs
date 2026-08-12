;;; test-helper.el --- Shared helpers for Beads tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'beads)

(defmacro beads-test-with-workspace (&rest body)
  "Run BODY in an isolated temporary Beads workspace."
  (declare (indent 0) (debug t))
  `(let ((root (make-temp-file "beads-test-" t)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name ".beads" root))
           (let ((default-directory root)
                 (beads-workspace nil)
                 (beads-default-workspace nil)
                 (beads-database-file nil))
             ,@body))
       (delete-directory root t))))

(defun beads-test-json (text)
  "Decode JSON TEXT through the package boundary."
  (beads-json-decode text))

(provide 'test-helper)

;;; test-helper.el ends here
