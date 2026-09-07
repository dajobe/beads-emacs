;;; beads.el --- Browse and manage Beads issues  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Dave Beckett <dave@dajobe.org>
;; Version: 0.1.4
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

(defconst beads-version "0.1.4"
  "Version of the beads-emacs package.

Keep this in sync with the Version header in beads.el.")

;;;###autoload
(defun beads-version ()
  "Return the beads-emacs package version, displaying it when interactive."
  (interactive)
  (when (called-interactively-p 'interactive)
    (message "beads-emacs %s" beads-version))
  beads-version)

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
      (princ (format "Workspace:   %s\n" workspace))
      (princ (format "beads-emacs: %s\n" beads-version))
      (princ (format "br:          %s\n" br-version))
      (princ (format "bv:          %s\n" viewer-version)))))

;;;###autoload
(defun beads (&optional directory)
  "Open the list of open Beads issues for DIRECTORY.

When called with a prefix argument, prompt for DIRECTORY."
  (interactive
   (list (when current-prefix-arg
           (read-directory-name "Beads workspace: " nil nil t))))
  (beads-list-open directory))

;;;###autoload (autoload 'bv "beads" "Open the list of open Beads issues." t)
;; This intentionally short entry point matches the companion executable.
(fset 'bv #'beads)

;;;###autoload
(defalias 'beads-open #'beads)

(provide 'beads)
;;; beads.el ends here
