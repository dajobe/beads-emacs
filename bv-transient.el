;;; bv-transient.el --- Discoverable Beads command menu  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Dave Beckett <dave@dajobe.org>

;;; Commentary:

;; A transient entry point covering views, analysis, and issue mutations.

;;; Code:

(require 'transient)
(require 'bv-list)
(require 'bv-show)
(require 'bv-triage)
(require 'bv-edit)

(declare-function bv-check "bv" (&optional directory))

(transient-define-prefix bv-list-menu ()
  "Open the command menu for a Beads issue list."
  [["Current list"
    ("g" "Refresh" bv-list-refresh)
    ("RET" "Show issue at point" bv-list-show)
    ("a" "All issues" bv-list-all)
    ("O" "Open" bv-list-open)
    ("o" "Open alias" bv-list-open)
    ("X" "Closed" bv-list-closed)
    ("r" "Ready" bv-list-ready)
    ("b" "Blocked" bv-list-blocked)
    ("l" "Label" bv-list-label)
    ("/" "Search" bv-list-search)
    ("s" "Show issue" bv-show)]
   ["Analyze"
    ("t" "Triage" bv-triage)
    ("n" "Next recommendation" bv-next)
    ("p" "Plan" bv-plan)
    ("V" "Check environment" bv-check)]
   ["Issue"
    ("c" "Create" bv-create)
    ("e" "Update" bv-update)
    ("C" "Claim" bv-claim)
    ("x" "Close" bv-close)
    ("R" "Reopen" bv-reopen)
    ("d" "Defer" bv-defer)
    ("u" "Undefer" bv-undefer)]
   ["Annotate"
    ("m" "Comment" bv-add-comment)
    ("A" "Add label" bv-add-label)
    ("L" "Remove label" bv-remove-label)
    ("+" "Add dependency" bv-add-dependency)
    ("-" "Remove dependency" bv-remove-dependency)]])

(transient-define-prefix bv-show-menu ()
  "Open the command menu for a Beads issue detail buffer."
  [["Current issue"
    ("g" "Refresh" bv-show-refresh)
    ("e" "Update" bv-update)
    ("C" "Claim" bv-claim)
    ("x" "Close" bv-close)
    ("R" "Reopen" bv-reopen)
    ("d" "Defer" bv-defer)
    ("c" "Comment" bv-add-comment)]
   ["Labels and dependencies"
    ("l a" "Add label" bv-add-label)
    ("l r" "Remove label" bv-remove-label)
    ("D a" "Add dependency" bv-add-dependency)
    ("D r" "Remove dependency" bv-remove-dependency)]
   ["Browse"
    ("a" "All issues" bv-list-all)
    ("O" "Open" bv-list-open)
    ("X" "Closed" bv-list-closed)
    ("r" "Ready" bv-list-ready)
    ("b" "Blocked" bv-list-blocked)
    ("/" "Search" bv-list-search)
    ("s" "Show issue" bv-show)]
   ["Analyze"
    ("t" "Triage" bv-triage)
    ("n" "Next recommendation" bv-next)
    ("p" "Plan" bv-plan)
    ("V" "Check environment" bv-check)]])

(transient-define-prefix bv-triage-menu ()
  "Open the command menu for a Beads analysis buffer."
  [["Current analysis"
    ("g" "Refresh" bv-triage-refresh)
    ("t" "Triage" bv-triage)
    ("p" "Plan" bv-plan)
    ("o" "Top recommendation" bv-next)
    ("n" "Next issue" forward-button)
    ("N" "Previous issue" backward-button)
    ("RET" "Open issue at point" push-button)]
   ["Browse"
    ("a" "All issues" bv-list-all)
    ("O" "Open" bv-list-open)
    ("X" "Closed" bv-list-closed)
    ("r" "Ready" bv-list-ready)
    ("b" "Blocked" bv-list-blocked)
    ("F" "Label" bv-list-label)
    ("/" "Search" bv-list-search)
    ("s" "Show issue" bv-show)]
   ["Issue"
    ("c" "Create" bv-create)
    ("e" "Update" bv-update)
    ("C" "Claim" bv-claim)
    ("x" "Close" bv-close)
    ("R" "Reopen" bv-reopen)
    ("d" "Defer" bv-defer)
    ("u" "Undefer" bv-undefer)]
   ["Annotate"
    ("m" "Comment" bv-add-comment)
    ("l" "Add label" bv-add-label)
    ("L" "Remove label" bv-remove-label)
    ("+" "Add dependency" bv-add-dependency)
    ("-" "Remove dependency" bv-remove-dependency)]])

(transient-define-prefix bv-general-menu ()
  "Open the general Beads command menu."
  [["Browse"
    ("a" "All issues" bv-list-all)
    ("O" "Open" bv-list-open)
    ("X" "Closed" bv-list-closed)
    ("r" "Ready" bv-list-ready)
    ("b" "Blocked" bv-list-blocked)
    ("F" "Label" bv-list-label)
    ("/" "Search" bv-list-search)
    ("s" "Show issue" bv-show)]
   ["Analyze"
    ("t" "Triage" bv-triage)
    ("n" "Next recommendation" bv-next)
    ("p" "Plan" bv-plan)
    ("V" "Check environment" bv-check)]
   ["Issue"
    ("c" "Create" bv-create)
    ("e" "Update" bv-update)
    ("C" "Claim" bv-claim)
    ("x" "Close" bv-close)
    ("R" "Reopen" bv-reopen)
    ("d" "Defer" bv-defer)
    ("u" "Undefer" bv-undefer)]
   ["Annotate"
    ("m" "Comment" bv-add-comment)
    ("l" "Add label" bv-add-label)
    ("L" "Remove label" bv-remove-label)
    ("+" "Add dependency" bv-add-dependency)
    ("-" "Remove dependency" bv-remove-dependency)]])

;;;###autoload
(defun bv-menu ()
  "Open the Beads command menu appropriate for the current buffer."
  (interactive)
  (call-interactively
   (cond
    ((derived-mode-p 'bv-list-mode) #'bv-list-menu)
    ((derived-mode-p 'bv-show-mode) #'bv-show-menu)
    ((derived-mode-p 'bv-triage-mode) #'bv-triage-menu)
    (t #'bv-general-menu))))

;;;###autoload
(defalias 'bv-transient #'bv-menu)

(provide 'bv-transient)
;;; bv-transient.el ends here
