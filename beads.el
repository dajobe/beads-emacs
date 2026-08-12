;;; beads.el --- Browse and manage Beads issues  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Dave Beckett <dave@dajobe.org>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.3.7"))
;; Keywords: tools, project
;; URL: https://github.com/dajobe/beads-emacs

;;; Commentary:

;; An Emacs interface to the `br' issue tracker and the graph-aware `bv'
;; analysis tool.  Run `M-x beads' (or its shorter alias `M-x bv') in a Beads
;; workspace to browse its issues.

;;; Code:

(require 'beads-core)
(require 'beads-list)
(require 'beads-show)
(require 'beads-triage)
(require 'beads-edit)
(require 'beads-transient)

(defun beads--version-string (executable)
  "Return version output from EXECUTABLE, or signal a user error."
  (condition-case resolution-error
      (let ((path (beads--resolve-executable executable)))
        (with-temp-buffer
          (let ((status (process-file path nil t nil "--version")))
            (unless (and (integerp status) (zerop status))
              (user-error "%s --version failed with status %s" path status))
            (string-trim (buffer-string)))))
    (file-missing
     (user-error "%s" (error-message-string resolution-error)))))

;;;###autoload
(defun beads-check (&optional directory)
  "Check Beads executables and the workspace at DIRECTORY."
  (interactive)
  (let* ((workspace (beads-workspace-root directory))
         (default-directory workspace)
         (br-version (beads--version-string beads-br-executable))
         (viewer-version (beads--version-string beads-bv-executable)))
    (with-help-window "*Beads check*"
      (princ "Beads environment\n\n")
      (princ (format "Workspace: %s\n" workspace))
      (princ (format "br:        %s\n" br-version))
      (princ (format "bv:        %s\n" viewer-version)))))

;;;###autoload
(defun beads (&optional directory)
  "Open the Beads issue list for DIRECTORY.

When called with a prefix argument, prompt for DIRECTORY."
  (interactive
   (list (when current-prefix-arg
           (read-directory-name "Beads workspace: " nil nil t))))
  (beads-list directory))

;;;###autoload (autoload 'bv "beads" "Open the Beads issue list." t)
;; This intentionally short entry point matches the companion executable.
(fset 'bv #'beads)

;;;###autoload
(defalias 'beads-open #'beads)

(provide 'beads)
;;; beads.el ends here
