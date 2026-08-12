;;; beads-transient.el --- Discoverable Beads command menu  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Dave Beckett <dave@dajobe.org>

;;; Commentary:

;; A transient entry point covering views, analysis, and issue mutations.

;;; Code:

(require 'transient)
(require 'beads-list)
(require 'beads-show)
(require 'beads-triage)
(require 'beads-edit)

(declare-function beads-check "beads" (&optional directory))

(transient-define-prefix beads-list-menu ()
                         "Open the command menu for a Beads issue list."
                         [["Current list"
                           ("g" "Refresh" beads-list-refresh)
                           ("RET" "Show issue at point" beads-list-show)
                           ("a" "All issues" beads-list-all)
                           ("O" "Open" beads-list-open)
                           ("o" "Open alias" beads-list-open)
                           ("X" "Closed" beads-list-closed)
                           ("r" "Ready" beads-list-ready)
                           ("b" "Blocked" beads-list-blocked)
                           ("l" "Label" beads-list-label)
                           ("/" "Search" beads-list-search)
                           ("s" "Show issue" beads-show)]
                          ["Analyze"
                           ("t" "Triage" beads-triage)
                           ("n" "Next recommendation" beads-next)
                           ("p" "Plan" beads-plan)
                           ("V" "Check environment" beads-check)]
                          ["Issue"
                           ("c" "Create" beads-create)
                           ("e" "Update" beads-update)
                           ("C" "Claim" beads-claim)
                           ("x" "Close" beads-close)
                           ("R" "Reopen" beads-reopen)
                           ("d" "Defer" beads-defer)
                           ("u" "Undefer" beads-undefer)]
                          ["Annotate"
                           ("m" "Comment" beads-add-comment)
                           ("A" "Add label" beads-add-label)
                           ("L" "Remove label" beads-remove-label)
                           ("+" "Add dependency" beads-add-dependency)
                           ("-" "Remove dependency" beads-remove-dependency)]])

(transient-define-prefix beads-show-menu ()
                         "Open the command menu for a Beads issue detail buffer."
                         [["Current issue"
                           ("g" "Refresh" beads-show-refresh)
                           ("e" "Update" beads-update)
                           ("C" "Claim" beads-claim)
                           ("x" "Close" beads-close)
                           ("R" "Reopen" beads-reopen)
                           ("d" "Defer" beads-defer)
                           ("c" "Comment" beads-add-comment)]
                          ["Labels and dependencies"
                           ("l a" "Add label" beads-add-label)
                           ("l r" "Remove label" beads-remove-label)
                           ("D a" "Add dependency" beads-add-dependency)
                           ("D r" "Remove dependency" beads-remove-dependency)]
                          ["Browse"
                           ("a" "All issues" beads-list-all)
                           ("O" "Open" beads-list-open)
                           ("X" "Closed" beads-list-closed)
                           ("r" "Ready" beads-list-ready)
                           ("b" "Blocked" beads-list-blocked)
                           ("/" "Search" beads-list-search)
                           ("s" "Show issue" beads-show)]
                          ["Analyze"
                           ("t" "Triage" beads-triage)
                           ("n" "Next recommendation" beads-next)
                           ("p" "Plan" beads-plan)
                           ("V" "Check environment" beads-check)]])

(transient-define-prefix beads-triage-menu ()
                         "Open the command menu for a Beads analysis buffer."
                         [["Current analysis"
                           ("g" "Refresh" beads-triage-refresh)
                           ("t" "Triage" beads-triage)
                           ("p" "Plan" beads-plan)
                           ("o" "Top recommendation" beads-next)
                           ("n" "Next issue" forward-button)
                           ("N" "Previous issue" backward-button)
                           ("RET" "Open issue at point" push-button)]
                          ["Browse"
                           ("a" "All issues" beads-list-all)
                           ("O" "Open" beads-list-open)
                           ("X" "Closed" beads-list-closed)
                           ("r" "Ready" beads-list-ready)
                           ("b" "Blocked" beads-list-blocked)
                           ("F" "Label" beads-list-label)
                           ("/" "Search" beads-list-search)
                           ("s" "Show issue" beads-show)]
                          ["Issue"
                           ("c" "Create" beads-create)
                           ("e" "Update" beads-update)
                           ("C" "Claim" beads-claim)
                           ("x" "Close" beads-close)
                           ("R" "Reopen" beads-reopen)
                           ("d" "Defer" beads-defer)
                           ("u" "Undefer" beads-undefer)]
                          ["Annotate"
                           ("m" "Comment" beads-add-comment)
                           ("l" "Add label" beads-add-label)
                           ("L" "Remove label" beads-remove-label)
                           ("+" "Add dependency" beads-add-dependency)
                           ("-" "Remove dependency" beads-remove-dependency)]])

(transient-define-prefix beads-general-menu ()
                         "Open the general Beads command menu."
                         [["Browse"
                           ("a" "All issues" beads-list-all)
                           ("O" "Open" beads-list-open)
                           ("X" "Closed" beads-list-closed)
                           ("r" "Ready" beads-list-ready)
                           ("b" "Blocked" beads-list-blocked)
                           ("F" "Label" beads-list-label)
                           ("/" "Search" beads-list-search)
                           ("s" "Show issue" beads-show)]
                          ["Analyze"
                           ("t" "Triage" beads-triage)
                           ("n" "Next recommendation" beads-next)
                           ("p" "Plan" beads-plan)
                           ("V" "Check environment" beads-check)]
                          ["Issue"
                           ("c" "Create" beads-create)
                           ("e" "Update" beads-update)
                           ("C" "Claim" beads-claim)
                           ("x" "Close" beads-close)
                           ("R" "Reopen" beads-reopen)
                           ("d" "Defer" beads-defer)
                           ("u" "Undefer" beads-undefer)]
                          ["Annotate"
                           ("m" "Comment" beads-add-comment)
                           ("l" "Add label" beads-add-label)
                           ("L" "Remove label" beads-remove-label)
                           ("+" "Add dependency" beads-add-dependency)
                           ("-" "Remove dependency" beads-remove-dependency)]])

;;;###autoload
(defun beads-menu ()
  "Open the Beads command menu appropriate for the current buffer."
  (interactive)
  (call-interactively
   (cond
    ((derived-mode-p 'beads-list-mode) #'beads-list-menu)
    ((derived-mode-p 'beads-show-mode) #'beads-show-menu)
    ((derived-mode-p 'beads-triage-mode) #'beads-triage-menu)
    (t #'beads-general-menu))))

;;;###autoload
(defalias 'beads-transient #'beads-menu)

(provide 'beads-transient)
;;; beads-transient.el ends here
