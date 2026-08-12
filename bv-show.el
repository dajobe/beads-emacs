;;; bv-show.el --- Beads issue detail buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Dave Beckett <dave@dajobe.org>

;;; Commentary:

;; A navigable, read-only rendering of one Beads issue.

;;; Code:

(require 'button)
(require 'easymenu)
(require 'seq)
(require 'subr-x)
(require 'bv-core)
(require 'bv-list)

(declare-function bv-claim "bv-edit" (&optional id workspace))
(declare-function bv-close "bv-edit" (&optional id workspace))
(declare-function bv-reopen "bv-edit" (&optional id workspace))
(declare-function bv-update "bv-edit" (&optional id workspace))
(declare-function bv-defer "bv-edit" (&optional id workspace))
(declare-function bv-add-comment "bv-edit" (&optional id workspace))
(declare-function bv-add-label "bv-edit" (&optional id workspace))
(declare-function bv-remove-label "bv-edit" (&optional id workspace))
(declare-function bv-add-dependency "bv-edit" (&optional id workspace))
(declare-function bv-remove-dependency "bv-edit" (&optional id workspace))
(declare-function bv-menu "bv-transient" ())

(defvar bv-show-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'bv-show-refresh)
    (define-key map (kbd "e") #'bv-update)
    (define-key map (kbd "C") #'bv-claim)
    (define-key map (kbd "x") #'bv-close)
    (define-key map (kbd "R") #'bv-reopen)
    (define-key map (kbd "d") #'bv-defer)
    (define-key map (kbd "c") #'bv-add-comment)
    (define-key map (kbd "l a") #'bv-add-label)
    (define-key map (kbd "l r") #'bv-remove-label)
    (define-key map (kbd "D a") #'bv-add-dependency)
    (define-key map (kbd "D r") #'bv-remove-dependency)
    (define-key map (kbd "?") #'bv-menu)
    map)
  "Keymap for `bv-show-mode'.")

(easy-menu-define bv-show-mode-menu bv-show-mode-map
  "Menu for a Beads issue detail buffer."
  '("Beads"
    ["Refresh" bv-show-refresh t]
    ["Edit..." bv-update t]
    ["Claim" bv-claim t]
    ["Close..." bv-close t]
    ["Reopen..." bv-reopen t]
    ["Defer..." bv-defer t]
    "---"
    ["Add comment..." bv-add-comment t]
    ["Add label..." bv-add-label t]
    ["Remove label..." bv-remove-label t]
    ["Add dependency..." bv-add-dependency t]
    ["Remove dependency..." bv-remove-dependency t]
    "---"
    ["Command menu" bv-menu t]))

(defvar-local bv-show-id nil
  "Identifier of the issue displayed in this buffer.")

(defvar-local bv-show-issue nil
  "Normalized issue object displayed in this buffer.")

(defvar-local bv-show--busy nil
  "Non-nil while this issue is being refreshed.")

(define-derived-mode bv-show-mode special-mode "Beads-Issue"
  "Major mode for a Beads issue detail buffer."
  (setq-local revert-buffer-function
              (lambda (&rest _ignored) (bv-show-refresh))))

(defun bv-show--string (value)
  "Return a friendly string representation of VALUE."
  (cond
   ((null value) "")
   ((eq value :json-false) "no")
   ((eq value t) "yes")
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   ((numberp value) (number-to-string value))
   (t (format "%s" value))))

(defun bv-show--insert-heading (heading)
  "Insert section HEADING."
  (unless (bolp) (insert "\n"))
  (insert (propertize heading 'face 'bv-section-heading-face) "\n"))

(defun bv-show--insert-field (label value &optional face)
  "Insert LABEL and VALUE when VALUE is present, using optional FACE."
  (let ((text (bv-show--string value)))
    (unless (string-empty-p text)
      (insert (propertize (concat label ":") 'face 'bold) " ")
      (insert (if face (propertize text 'face face) text) "\n"))))

(defun bv-show--button-action (button)
  "Open the issue stored on BUTTON."
  (bv-show (button-get button 'bv-issue-id)
           (button-get button 'bv-workspace)))

(defun bv-show--insert-id-button (id &optional title)
  "Insert a button for issue ID with optional TITLE."
  (insert-text-button
   (if (and title (not (string-empty-p title)))
       (format "%s  %s" id title)
     id)
   'bv-issue-id id
   'bv-workspace bv-workspace
   'face 'bv-issue-id-face
   'follow-link t
   'help-echo (format "Open issue %s" id)
   'action #'bv-show--button-action))

(defun bv-show--insert-labels (labels)
  "Insert LABELS as a compact line."
  (when labels
    (insert (propertize "Labels:" 'face 'bold) " ")
    (insert (mapconcat #'bv-show--string labels ", ") "\n")))

(defun bv-show--insert-relations (heading relations)
  "Insert HEADING followed by issue RELATIONS."
  (when relations
    (bv-show--insert-heading heading)
    (dolist (relation relations)
      (insert "  • ")
      (bv-show--insert-id-button
       (bv-show--string (bv-object-get relation 'id))
       (bv-show--string (bv-object-get relation 'title)))
      (let ((type (bv-show--string
                   (bv-object-get relation 'dependency_type))))
        (unless (string-empty-p type)
          (insert (propertize (format "  [%s]" type) 'face 'bv-muted-face))))
      (insert "\n"))))

(defun bv-show--insert-text-section (heading text)
  "Insert HEADING and TEXT if TEXT is nonempty."
  (let ((text (bv-show--string text)))
    (unless (string-empty-p text)
      (bv-show--insert-heading heading)
      (insert text)
      (unless (bolp) (insert "\n")))))

(defun bv-show--status-face (status)
  "Return the appropriate face for STATUS."
  (pcase (bv-show--string status)
    ("closed" 'bv-status-closed-face)
    ("in_progress" 'bv-status-progress-face)
    ("blocked" 'bv-status-blocked-face)
    ("open" 'bv-status-open-face)
    (_ 'default)))

(defun bv-show--insert-comments (comments)
  "Insert issue COMMENTS."
  (when comments
    (bv-show--insert-heading "Comments")
    (dolist (comment comments)
      (let ((author (or (bv-object-get comment 'author)
                        (bv-object-get comment 'created_by)
                        "unknown"))
            (date (or (bv-object-get comment 'created_at) ""))
            (text (or (bv-object-get comment 'text)
                      (bv-object-get comment 'content)
                      (bv-object-get comment 'body)
                      "")))
        (insert (propertize (format "%s  %s" author date)
                            'face 'bv-muted-face)
                "  " (bv-show--string text) "\n\n")))))

(defun bv-show-render (issue)
  "Render normalized ISSUE in the current buffer."
  (let ((inhibit-read-only t)
        (point-position (point)))
    (erase-buffer)
    (let ((title (bv-show--string (bv-object-get issue 'title)))
          (id (bv-show--string (bv-object-get issue 'id))))
      (insert (propertize title 'face '(:height 1.35 :weight bold)) "\n")
      (insert (propertize id 'face 'bv-issue-id-face) "\n\n")
      (let ((status (bv-object-get issue 'status)))
        (bv-show--insert-field "Status" status
                               (bv-show--status-face status)))
      (bv-show--insert-field
       "Priority"
       (let ((value (bv-object-get issue 'priority)))
         (and value (format "P%s" value))))
      (bv-show--insert-field "Type" (bv-object-get issue 'issue_type))
      (bv-show--insert-field "Assignee" (bv-object-get issue 'assignee))
      (bv-show--insert-field "Owner" (bv-object-get issue 'owner))
      (bv-show--insert-field "Due" (bv-object-get issue 'due_at))
      (bv-show--insert-field "Deferred until"
                             (or (bv-object-get issue 'defer_until)
                                 (bv-object-get issue 'deferred_until)))
      (bv-show--insert-labels (bv-object-get issue 'labels))
      (bv-show--insert-text-section "Description"
                                    (bv-object-get issue 'description))
      (bv-show--insert-text-section
       "Acceptance criteria" (bv-object-get issue 'acceptance_criteria))
      (bv-show--insert-text-section "Design" (bv-object-get issue 'design))
      (bv-show--insert-text-section "Notes" (bv-object-get issue 'notes))
      (bv-show--insert-relations "Depends on"
                                 (bv-object-get issue 'dependencies))
      (bv-show--insert-relations "Unblocks"
                                 (bv-object-get issue 'dependents))
      (bv-show--insert-comments (bv-object-get issue 'comments))
      (bv-show--insert-heading "History")
      (bv-show--insert-field "Created" (bv-object-get issue 'created_at))
      (bv-show--insert-field "Updated" (bv-object-get issue 'updated_at))
      (bv-show--insert-field "Closed" (bv-object-get issue 'closed_at))
      (goto-char (min point-position (point-max))))))

(defun bv-show--set-busy (busy)
  "Set the issue buffer BUSY indicator."
  (setq bv-show--busy busy
        mode-line-process
        (and busy '(" " (:propertize "loading" face warning))))
  (force-mode-line-update))

(defun bv-show-refresh ()
  "Refresh the issue in the current detail buffer."
  (interactive)
  (unless (and (derived-mode-p 'bv-show-mode) bv-show-id)
    (user-error "This is not a Beads issue buffer"))
  (let ((buffer (current-buffer)))
    (bv-show--set-busy t)
    (bv-br-async
     (list "show" bv-show-id "--json")
     (lambda (json)
       (let ((issues (bv-json-issues json)))
         (unless issues
           (signal 'bv-json-error (list "Show returned no issue")))
         (setq bv-show-issue (car issues))
         (bv-show--set-busy nil)
         (bv-show-render bv-show-issue)))
     (lambda (error-data)
       (bv-show--set-busy nil)
       (message "Could not load issue %s: %s" bv-show-id error-data))
     bv-workspace buffer)))

(defun bv-show--buffer-name (id workspace)
  "Return the detail buffer name for ID in WORKSPACE."
  (format "*Beads %s: %s*"
          id (file-name-nondirectory (directory-file-name workspace))))

;;;###autoload
(defun bv-show (id &optional workspace)
  "Display issue ID from WORKSPACE."
  (interactive (list (read-string "Issue ID: ") nil))
  (when (string-empty-p id)
    (user-error "Issue ID cannot be empty"))
  (let* ((root (bv-workspace-root workspace))
         (buffer (get-buffer-create (bv-show--buffer-name id root))))
    (with-current-buffer buffer
      (bv-show-mode)
      (setq-local bv-workspace root)
      (setq-local bv-show-id id)
      (bv-show-refresh))
    (pop-to-buffer buffer)
    buffer))

(provide 'bv-show)
;;; bv-show.el ends here
