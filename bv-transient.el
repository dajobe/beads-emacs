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

;;;###autoload (autoload 'bv-menu "bv-transient" nil t)
(transient-define-prefix bv-menu ()
  "Open the Beads command menu."
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
(defalias 'bv-transient #'bv-menu)

(provide 'bv-transient)
;;; bv-transient.el ends here
