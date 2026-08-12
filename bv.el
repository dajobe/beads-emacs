;;; bv.el --- Browse and manage Beads issues  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Dave Beckett <dave@dajobe.org>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.3.7"))
;; Keywords: tools, project
;; URL: https://github.com/dajobe/bv-emacs

;;; Commentary:

;; An Emacs interface to the `br' issue tracker and the graph-aware `bv'
;; analysis tool.  Run `M-x bv' in a Beads workspace to browse its issues.

;;; Code:

(require 'bv-core)
(require 'bv-list)
(require 'bv-show)
(require 'bv-triage)
(require 'bv-edit)
(require 'bv-transient)

(defun bv--version-string (executable)
  "Return version output from EXECUTABLE, or signal a user error."
  (let ((path (executable-find executable)))
    (unless path
      (user-error "Beads executable not found: %s" executable))
    (with-temp-buffer
      (let ((status (process-file path nil t nil "--version")))
        (unless (and (integerp status) (zerop status))
          (user-error "%s --version failed with status %s" path status))
        (string-trim (buffer-string))))))

;;;###autoload
(defun bv-check (&optional directory)
  "Check Beads executables and the workspace at DIRECTORY."
  (interactive)
  (let* ((workspace (bv-workspace-root directory))
         (default-directory workspace)
         (br-version (bv--version-string bv-br-executable))
         (bv-version (bv--version-string bv-bv-executable)))
    (with-help-window "*Beads check*"
      (princ "Beads environment\n\n")
      (princ (format "Workspace: %s\n" workspace))
      (princ (format "br:        %s\n" br-version))
      (princ (format "bv:        %s\n" bv-version)))))

;;;###autoload
(defun bv (&optional directory)
  "Open the Beads issue list for DIRECTORY.

When called with a prefix argument, prompt for DIRECTORY."
  (interactive
   (list (when current-prefix-arg
           (read-directory-name "Beads workspace: " nil nil t))))
  (bv-list directory))

;;;###autoload
(defalias 'bv-open #'bv)

(provide 'bv)
;;; bv.el ends here
