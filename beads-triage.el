;;; beads-triage.el --- Graph-aware Beads analysis views  -*- lexical-binding: t; -*-

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
(require 'beads-core)
(require 'beads-list)

(declare-function beads-show "beads-show" (id &optional workspace))
(declare-function beads-menu "beads-transient" ())

(defvar beads-triage-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'beads-triage-refresh)
    (define-key map (kbd "t") #'beads-triage)
    (define-key map (kbd "p") #'beads-plan)
    (define-key map (kbd "o") #'beads-next)
    (define-key map (kbd "n") #'forward-button)
    (define-key map (kbd "N") #'backward-button)
    (define-key map (kbd "RET") #'push-button)
    (define-key map (kbd "?") #'beads-menu)
    map)
  "Keymap for `beads-triage-mode'.")

(easy-menu-define beads-triage-mode-menu beads-triage-mode-map
  "Menu for Beads analysis buffers."
  '("Beads"
    ["Refresh" beads-triage-refresh t]
    ["Triage" beads-triage t]
    ["Next recommendation" beads-next t]
    ["Plan" beads-plan t]
    "---"
    ["Next issue" forward-button t]
    ["Previous issue" backward-button t]
    ["Command menu" beads-menu t]))

(defvar-local beads-triage-kind 'triage
  "Analysis kind displayed in the current buffer.")

(defvar-local beads-triage-data nil
  "Last successful normalized analysis response.")

(defvar-local beads-triage--busy nil
  "Non-nil while an analysis request is active.")

(define-derived-mode beads-triage-mode special-mode "Beads-Analysis"
  "Major mode for graph-aware Beads analysis."
  (setq-local revert-buffer-function
              (lambda (&rest _ignored) (beads-triage-refresh))))

(defun beads-triage--string (value)
  "Convert VALUE to a concise string."
  (cond
   ((null value) "")
   ((eq value :json-false) "no")
   ((eq value t) "yes")
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%s" value))))

(defun beads-triage--heading (text &optional level)
  "Insert heading TEXT at LEVEL one or two."
  (unless (bolp) (insert "\n"))
  (insert (propertize text 'face
                      (if (= (or level 1) 1)
                          '(:inherit beads-section-heading-face :height 1.2)
                        'beads-section-heading-face))
          "\n"))

(defun beads-triage--issue-action (button)
  "Open the issue associated with BUTTON."
  (beads-show (button-get button 'beads-issue-id)
              (button-get button 'beads-workspace)))

(defun beads-triage--issue-button (item)
  "Insert a navigable issue button for ITEM."
  (let ((id (beads-triage--string (beads-object-get item 'id)))
        (title (beads-triage--string (beads-object-get item 'title))))
    (insert-text-button
     (if (string-empty-p title) id (format "%s  %s" id title))
     'beads-issue-id id
     'beads-workspace beads-workspace
     'face 'beads-issue-id-face
     'follow-link t
     'help-echo (format "Open issue %s" id)
     'action #'beads-triage--issue-action)))

(defun beads-triage--insert-summary (summary)
  "Insert count and summary fields from SUMMARY."
  (when summary
    (beads-triage--heading "Overview" 2)
    (dolist (field '((open_count . "Open")
                     (actionable_count . "Actionable")
                     (blocked_count . "Blocked")
                     (in_progress_count . "In progress")
                     (not_actionable_count . "Not actionable")
                     (total_actionable . "Actionable")
                     (total_blocked . "Blocked")))
      (let ((value (beads-object-get summary (car field) :missing)))
        (unless (eq value :missing)
          (insert (format "%-17s %s\n" (concat (cdr field) ":") value)))))))

(defun beads-triage--insert-items (heading items)
  "Insert HEADING followed by issue ITEMS."
  (when items
    (beads-triage--heading heading 2)
    (dolist (item items)
      (insert "  • ")
      (beads-triage--issue-button item)
      (let ((status (beads-object-get item 'status))
            (score (beads-object-get item 'score))
            (reason (beads-object-get item 'reason))
            (reasons (beads-object-get item 'reasons)))
        (when status
          (insert (propertize
                   (format "  [%s]" (replace-regexp-in-string
                                     "_" " " (beads-triage--string status)))
                   'face 'beads-muted-face)))
        (when (numberp score)
          (insert (propertize (format "  score %.3f" score)
                              'face 'beads-muted-face)))
        (when reason
          (insert "\n      " (beads-triage--string reason)))
        (dolist (entry reasons)
          (insert "\n      "
                  (beads-triage--string
                   (if (listp entry)
                       (or (beads-object-get entry 'reason)
                           (beads-object-get entry 'message)
                           entry)
                     entry)))))
      (let ((blocked (beads-object-get item 'blocked_by))
            (unblocks (beads-object-get item 'unblocks)))
        (when blocked
          (insert "\n      blocked by "
                  (mapconcat #'beads-triage--string blocked ", ")))
        (when unblocks
          (insert "\n      unblocks "
                  (mapconcat #'beads-triage--string unblocks ", "))))
      (insert "\n"))))

(defun beads-triage--render-triage (data)
  "Render a triage DATA response."
  (let ((triage (or (beads-object-get data 'triage) data)))
    (beads-triage--heading "Beads triage")
    (beads-triage--insert-summary (beads-object-get triage 'quick_ref))
    (beads-triage--insert-items
     "Top picks" (beads-object-get (beads-object-get triage 'quick_ref) 'top_picks))
    (beads-triage--insert-items
     "Recommendations" (beads-object-get triage 'recommendations))
    (beads-triage--insert-items "Quick wins" (beads-object-get triage 'quick_wins))
    (beads-triage--insert-items
     "Blockers to clear" (beads-object-get triage 'blockers_to_clear))))

(defun beads-triage--render-track (track)
  "Render one execution TRACK."
  (let ((id (beads-triage--string (beads-object-get track 'track_id)))
        (reason (beads-object-get track 'reason)))
    (beads-triage--heading (if (string-empty-p id) "Track" id) 2)
    (when reason
      (insert (propertize (concat (beads-triage--string reason) "\n")
                          'face 'beads-muted-face)))
    (dolist (item (beads-object-get track 'items))
      (insert "  • ")
      (beads-triage--issue-button item)
      (let ((priority (beads-object-get item 'priority))
            (status (beads-object-get item 'status))
            (unblocks (beads-object-get item 'unblocks)))
        (when priority (insert (format "  P%s" priority)))
        (when status (insert (format "  [%s]" status)))
        (when unblocks
          (insert "\n      unblocks "
                  (mapconcat #'beads-triage--string unblocks ", "))))
      (insert "\n"))))

(defun beads-triage--render-plan (data)
  "Render a planning DATA response."
  (let ((plan (or (beads-object-get data 'plan) data)))
    (beads-triage--heading "Beads execution plan")
    (beads-triage--insert-summary plan)
    (dolist (track (beads-object-get plan 'tracks))
      (beads-triage--render-track track))
    (let ((summary (beads-object-get plan 'summary)))
      (when summary
        (beads-triage--heading "Plan summary" 2)
        (let ((impact (beads-object-get summary 'highest_impact))
              (reason (beads-object-get summary 'impact_reason)))
          (when impact
            (insert (format "Highest impact: %s\n" impact)))
          (when reason
            (insert (format "%s\n" reason))))))))

(defun beads-triage--render-next (data)
  "Render a robot-next DATA response."
  (beads-triage--heading "Next Beads recommendation")
  (cond
   ((beads-object-get data 'id)
    (beads-triage--insert-items "Recommended issue" (list data)))
   ((beads-object-get data 'recommendation)
    (beads-triage--insert-items
     "Recommended issue" (list (beads-object-get data 'recommendation))))
   (t
    (insert (or (beads-object-get data 'message)
                "No actionable recommendation is available")
            "\n")
    (let ((degraded (beads-object-get data 'degraded)))
      (when degraded
        (beads-triage--heading "Why" 2)
        (dolist (entry degraded)
          (insert "  • " (beads-triage--string
                          (or (beads-object-get entry 'message) entry)) "\n")
          (let ((repair (beads-object-get entry 'repair)))
            (when repair
              (insert "      " (beads-triage--string repair) "\n")))))))))

(defun beads-triage-render (kind data)
  "Render analysis DATA of KIND in the current buffer."
  (let ((inhibit-read-only t)
        (position (point)))
    (erase-buffer)
    (pcase kind
      ('triage (beads-triage--render-triage data))
      ('plan (beads-triage--render-plan data))
      ('next (beads-triage--render-next data))
      (_ (error "Unsupported Beads analysis kind: %S" kind)))
    (goto-char (min position (point-max)))))

(defun beads-triage--args ()
  "Return argv for the analysis in the current buffer."
  (pcase beads-triage-kind
    ('triage '("--robot-triage" "--brief" "--format" "json"))
    ('plan '("--robot-plan" "--format" "json"))
    ('next '("--robot-next" "--format" "json"))
    (_ (error "Unsupported Beads analysis kind: %S" beads-triage-kind))))

(defun beads-triage--set-busy (busy)
  "Set analysis BUSY indicator."
  (setq beads-triage--busy busy
        mode-line-process
        (and busy '(" " (:propertize "analyzing" face warning))))
  (force-mode-line-update))

(defun beads-triage-refresh ()
  "Refresh the current graph-aware analysis."
  (interactive)
  (unless (derived-mode-p 'beads-triage-mode)
    (user-error "This is not a Beads analysis buffer"))
  (let ((buffer (current-buffer)))
    (beads-triage--set-busy t)
    (beads-bv-async
     (beads-triage--args)
     (lambda (json)
       (setq beads-triage-data json)
       (beads-triage--set-busy nil)
       (beads-triage-render beads-triage-kind json))
     (lambda (error-data)
       (beads-triage--set-busy nil)
       (message "Beads analysis failed: %s" error-data))
     beads-workspace buffer)))

(defun beads-triage--buffer-name (kind workspace)
  "Return buffer name for analysis KIND in WORKSPACE."
  (format "*Beads %s: %s*"
          (capitalize (symbol-name kind))
          (file-name-nondirectory (directory-file-name workspace))))

(defun beads-triage--open (kind &optional workspace)
  "Open analysis KIND for WORKSPACE."
  (let* ((root (beads-workspace-root workspace))
         (buffer (get-buffer-create (beads-triage--buffer-name kind root))))
    (with-current-buffer buffer
      (beads-triage-mode)
      (setq-local beads-workspace root)
      (setq-local beads-triage-kind kind)
      (beads-watch-workspace #'beads-triage-refresh)
      (beads-triage-refresh))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun beads-triage (&optional workspace)
  "Open graph-aware triage for WORKSPACE."
  (interactive)
  (beads-triage--open 'triage (or workspace beads-workspace)))

;;;###autoload
(defun beads-plan (&optional workspace)
  "Open the dependency-aware execution plan for WORKSPACE."
  (interactive)
  (beads-triage--open 'plan (or workspace beads-workspace)))

;;;###autoload
(defun beads-next (&optional workspace)
  "Open the single top recommendation for WORKSPACE."
  (interactive)
  (beads-triage--open 'next (or workspace beads-workspace)))

(provide 'beads-triage)
;;; beads-triage.el ends here
