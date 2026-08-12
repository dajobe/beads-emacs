;;; bv-triage.el --- Graph-aware Beads analysis views  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Dave Beckett <dave@dajobe.org>

;;; Commentary:

;; Read-only renderers for the structured triage and planning interfaces of
;; `bv'.  Issue identifiers are buttons leading to detail buffers.

;;; Code:

(require 'button)
(require 'easymenu)
(require 'seq)
(require 'subr-x)
(require 'bv-core)
(require 'bv-list)

(declare-function bv-show "bv-show" (id &optional workspace))
(declare-function bv-menu "bv-transient" ())

(defvar bv-triage-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'bv-triage-refresh)
    (define-key map (kbd "t") #'bv-triage)
    (define-key map (kbd "p") #'bv-plan)
    (define-key map (kbd "o") #'bv-next)
    (define-key map (kbd "n") #'forward-button)
    (define-key map (kbd "N") #'backward-button)
    (define-key map (kbd "RET") #'push-button)
    (define-key map (kbd "?") #'bv-menu)
    map)
  "Keymap for `bv-triage-mode'.")

(easy-menu-define bv-triage-mode-menu bv-triage-mode-map
  "Menu for Beads analysis buffers."
  '("Beads"
    ["Refresh" bv-triage-refresh t]
    ["Triage" bv-triage t]
    ["Next recommendation" bv-next t]
    ["Plan" bv-plan t]
    "---"
    ["Next issue" forward-button t]
    ["Previous issue" backward-button t]
    ["Command menu" bv-menu t]))

(defvar-local bv-triage-kind 'triage
  "Analysis kind displayed in the current buffer.")

(defvar-local bv-triage-data nil
  "Last successful normalized analysis response.")

(defvar-local bv-triage--busy nil
  "Non-nil while an analysis request is active.")

(define-derived-mode bv-triage-mode special-mode "Beads-Analysis"
  "Major mode for graph-aware Beads analysis."
  (setq-local revert-buffer-function
              (lambda (&rest _ignored) (bv-triage-refresh))))

(defun bv-triage--string (value)
  "Convert VALUE to a concise string."
  (cond
   ((null value) "")
   ((eq value :json-false) "no")
   ((eq value t) "yes")
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%s" value))))

(defun bv-triage--heading (text &optional level)
  "Insert heading TEXT at LEVEL one or two."
  (unless (bolp) (insert "\n"))
  (insert (propertize text 'face
                      (if (= (or level 1) 1)
                          '(:inherit bv-section-heading-face :height 1.2)
                        'bv-section-heading-face))
          "\n"))

(defun bv-triage--issue-action (button)
  "Open the issue associated with BUTTON."
  (bv-show (button-get button 'bv-issue-id)
           (button-get button 'bv-workspace)))

(defun bv-triage--issue-button (item)
  "Insert a navigable issue button for ITEM."
  (let ((id (bv-triage--string (bv-object-get item 'id)))
        (title (bv-triage--string (bv-object-get item 'title))))
    (insert-text-button
     (if (string-empty-p title) id (format "%s  %s" id title))
     'bv-issue-id id
     'bv-workspace bv-workspace
     'face 'bv-issue-id-face
     'follow-link t
     'help-echo (format "Open issue %s" id)
     'action #'bv-triage--issue-action)))

(defun bv-triage--insert-summary (summary)
  "Insert count and summary fields from SUMMARY."
  (when summary
    (bv-triage--heading "Overview" 2)
    (dolist (field '((open_count . "Open")
                     (actionable_count . "Actionable")
                     (blocked_count . "Blocked")
                     (in_progress_count . "In progress")
                     (not_actionable_count . "Not actionable")
                     (total_actionable . "Actionable")
                     (total_blocked . "Blocked")))
      (let ((value (bv-object-get summary (car field) :missing)))
        (unless (eq value :missing)
          (insert (format "%-17s %s\n" (concat (cdr field) ":") value)))))))

(defun bv-triage--insert-items (heading items)
  "Insert HEADING followed by issue ITEMS."
  (when items
    (bv-triage--heading heading 2)
    (dolist (item items)
      (insert "  • ")
      (bv-triage--issue-button item)
      (let ((status (bv-object-get item 'status))
            (score (bv-object-get item 'score))
            (reason (bv-object-get item 'reason))
            (reasons (bv-object-get item 'reasons)))
        (when status
          (insert (propertize
                   (format "  [%s]" (replace-regexp-in-string
                                     "_" " " (bv-triage--string status)))
                   'face 'bv-muted-face)))
        (when (numberp score)
          (insert (propertize (format "  score %.3f" score)
                              'face 'bv-muted-face)))
        (when reason
          (insert "\n      " (bv-triage--string reason)))
        (dolist (entry reasons)
          (insert "\n      "
                  (bv-triage--string
                   (if (listp entry)
                       (or (bv-object-get entry 'reason)
                           (bv-object-get entry 'message)
                           entry)
                     entry)))))
      (let ((blocked (bv-object-get item 'blocked_by))
            (unblocks (bv-object-get item 'unblocks)))
        (when blocked
          (insert "\n      blocked by "
                  (mapconcat #'bv-triage--string blocked ", ")))
        (when unblocks
          (insert "\n      unblocks "
                  (mapconcat #'bv-triage--string unblocks ", "))))
      (insert "\n"))))

(defun bv-triage--render-triage (data)
  "Render a triage DATA response."
  (let ((triage (or (bv-object-get data 'triage) data)))
    (bv-triage--heading "Beads triage")
    (bv-triage--insert-summary (bv-object-get triage 'quick_ref))
    (bv-triage--insert-items
     "Top picks" (bv-object-get (bv-object-get triage 'quick_ref) 'top_picks))
    (bv-triage--insert-items
     "Recommendations" (bv-object-get triage 'recommendations))
    (bv-triage--insert-items "Quick wins" (bv-object-get triage 'quick_wins))
    (bv-triage--insert-items
     "Blockers to clear" (bv-object-get triage 'blockers_to_clear))))

(defun bv-triage--render-track (track)
  "Render one execution TRACK."
  (let ((id (bv-triage--string (bv-object-get track 'track_id)))
        (reason (bv-object-get track 'reason)))
    (bv-triage--heading (if (string-empty-p id) "Track" id) 2)
    (when reason
      (insert (propertize (concat (bv-triage--string reason) "\n")
                          'face 'bv-muted-face)))
    (dolist (item (bv-object-get track 'items))
      (insert "  • ")
      (bv-triage--issue-button item)
      (let ((priority (bv-object-get item 'priority))
            (status (bv-object-get item 'status))
            (unblocks (bv-object-get item 'unblocks)))
        (when priority (insert (format "  P%s" priority)))
        (when status (insert (format "  [%s]" status)))
        (when unblocks
          (insert "\n      unblocks "
                  (mapconcat #'bv-triage--string unblocks ", "))))
      (insert "\n"))))

(defun bv-triage--render-plan (data)
  "Render a planning DATA response."
  (let ((plan (or (bv-object-get data 'plan) data)))
    (bv-triage--heading "Beads execution plan")
    (bv-triage--insert-summary plan)
    (dolist (track (bv-object-get plan 'tracks))
      (bv-triage--render-track track))
    (let ((summary (bv-object-get plan 'summary)))
      (when summary
        (bv-triage--heading "Plan summary" 2)
        (let ((impact (bv-object-get summary 'highest_impact))
              (reason (bv-object-get summary 'impact_reason)))
          (when impact
            (insert (format "Highest impact: %s\n" impact)))
          (when reason
            (insert (format "%s\n" reason))))))))

(defun bv-triage--render-next (data)
  "Render a robot-next DATA response."
  (bv-triage--heading "Next Beads recommendation")
  (cond
   ((bv-object-get data 'id)
    (bv-triage--insert-items "Recommended issue" (list data)))
   ((bv-object-get data 'recommendation)
    (bv-triage--insert-items
     "Recommended issue" (list (bv-object-get data 'recommendation))))
   (t
    (insert (or (bv-object-get data 'message)
                "No actionable recommendation is available")
            "\n")
    (let ((degraded (bv-object-get data 'degraded)))
      (when degraded
        (bv-triage--heading "Why" 2)
        (dolist (entry degraded)
          (insert "  • " (bv-triage--string
                           (or (bv-object-get entry 'message) entry)) "\n")
          (let ((repair (bv-object-get entry 'repair)))
            (when repair
              (insert "      " (bv-triage--string repair) "\n")))))))))

(defun bv-triage-render (kind data)
  "Render analysis DATA of KIND in the current buffer."
  (let ((inhibit-read-only t)
        (position (point)))
    (erase-buffer)
    (pcase kind
      ('triage (bv-triage--render-triage data))
      ('plan (bv-triage--render-plan data))
      ('next (bv-triage--render-next data))
      (_ (error "Unsupported Beads analysis kind: %S" kind)))
    (goto-char (min position (point-max)))))

(defun bv-triage--args ()
  "Return argv for the analysis in the current buffer."
  (pcase bv-triage-kind
    ('triage '("--robot-triage" "--brief" "--format" "json"))
    ('plan '("--robot-plan" "--format" "json"))
    ('next '("--robot-next" "--format" "json"))
    (_ (error "Unsupported Beads analysis kind: %S" bv-triage-kind))))

(defun bv-triage--set-busy (busy)
  "Set analysis BUSY indicator."
  (setq bv-triage--busy busy
        mode-line-process
        (and busy '(" " (:propertize "analyzing" face warning))))
  (force-mode-line-update))

(defun bv-triage-refresh ()
  "Refresh the current graph-aware analysis."
  (interactive)
  (unless (derived-mode-p 'bv-triage-mode)
    (user-error "This is not a Beads analysis buffer"))
  (let ((buffer (current-buffer)))
    (bv-triage--set-busy t)
    (bv-bv-async
     (bv-triage--args)
     (lambda (json)
       (setq bv-triage-data json)
       (bv-triage--set-busy nil)
       (bv-triage-render bv-triage-kind json))
     (lambda (error-data)
       (bv-triage--set-busy nil)
       (message "Beads analysis failed: %s" error-data))
     bv-workspace buffer)))

(defun bv-triage--buffer-name (kind workspace)
  "Return buffer name for analysis KIND in WORKSPACE."
  (format "*Beads %s: %s*"
          (capitalize (symbol-name kind))
          (file-name-nondirectory (directory-file-name workspace))))

(defun bv-triage--open (kind &optional workspace)
  "Open analysis KIND for WORKSPACE."
  (let* ((root (bv-workspace-root workspace))
         (buffer (get-buffer-create (bv-triage--buffer-name kind root))))
    (with-current-buffer buffer
      (bv-triage-mode)
      (setq-local bv-workspace root)
      (setq-local bv-triage-kind kind)
      (bv-triage-refresh))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun bv-triage (&optional workspace)
  "Open graph-aware triage for WORKSPACE."
  (interactive)
  (bv-triage--open 'triage (or workspace bv-workspace)))

;;;###autoload
(defun bv-plan (&optional workspace)
  "Open the dependency-aware execution plan for WORKSPACE."
  (interactive)
  (bv-triage--open 'plan (or workspace bv-workspace)))

;;;###autoload
(defun bv-next (&optional workspace)
  "Open the single top recommendation for WORKSPACE."
  (interactive)
  (bv-triage--open 'next (or workspace bv-workspace)))

(provide 'bv-triage)
;;; bv-triage.el ends here
