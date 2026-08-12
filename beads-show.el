;;; beads-show.el --- Beads issue detail buffers  -*- lexical-binding: t; -*-

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
(require 'beads-core)
(require 'beads-list)

(declare-function beads-claim "beads-edit" (&optional id workspace))
(declare-function beads-close "beads-edit" (&optional id workspace))
(declare-function beads-reopen "beads-edit" (&optional id workspace))
(declare-function beads-update "beads-edit" (&optional id workspace))
(declare-function beads-defer "beads-edit" (&optional id workspace))
(declare-function beads-add-comment "beads-edit" (&optional id workspace))
(declare-function beads-add-label "beads-edit" (&optional id workspace))
(declare-function beads-remove-label "beads-edit" (&optional id workspace))
(declare-function beads-add-dependency "beads-edit" (&optional id workspace))
(declare-function beads-remove-dependency "beads-edit" (&optional id workspace))
(declare-function beads-menu "beads-transient" ())

(defcustom beads-show-buffer-name "*Beads issue*"
  "Name of the reusable buffer used to display issue details."
  :type 'string
  :group 'beads)

(defvar beads-show-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'beads-show-refresh)
    (define-key map (kbd "e") #'beads-update)
    (define-key map (kbd "C") #'beads-claim)
    (define-key map (kbd "x") #'beads-close)
    (define-key map (kbd "R") #'beads-reopen)
    (define-key map (kbd "d") #'beads-defer)
    (define-key map (kbd "c") #'beads-add-comment)
    (define-key map (kbd "l a") #'beads-add-label)
    (define-key map (kbd "l r") #'beads-remove-label)
    (define-key map (kbd "D a") #'beads-add-dependency)
    (define-key map (kbd "D r") #'beads-remove-dependency)
    (define-key map (kbd "?") #'beads-menu)
    map)
  "Keymap for `beads-show-mode'.")

(easy-menu-define beads-show-mode-menu beads-show-mode-map
  "Menu for a Beads issue detail buffer."
  '("Beads"
    ["Refresh" beads-show-refresh t]
    ["Edit..." beads-update t]
    ["Claim" beads-claim t]
    ["Close..." beads-close t]
    ["Reopen..." beads-reopen t]
    ["Defer..." beads-defer t]
    "---"
    ["Add comment..." beads-add-comment t]
    ["Add label..." beads-add-label t]
    ["Remove label..." beads-remove-label t]
    ["Add dependency..." beads-add-dependency t]
    ["Remove dependency..." beads-remove-dependency t]
    "---"
    ["Command menu" beads-menu t]))

(defvar-local beads-show-id nil
  "Identifier of the issue displayed in this buffer.")

(defvar-local beads-show-issue nil
  "Normalized issue object displayed in this buffer.")

(defvar-local beads-show--busy nil
  "Non-nil while this issue is being refreshed.")

(define-derived-mode beads-show-mode special-mode "Beads-Issue"
  "Major mode for a Beads issue detail buffer."
  (setq-local truncate-lines nil
              word-wrap t)
  (visual-line-mode 1)
  (setq-local revert-buffer-function
              (lambda (&rest _ignored) (beads-show-refresh))))

(defun beads-show--string (value)
  "Return a friendly string representation of VALUE."
  (cond
   ((null value) "")
   ((eq value :json-false) "no")
   ((eq value t) "yes")
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   ((numberp value) (number-to-string value))
   (t (format "%s" value))))

(defun beads-show--insert-heading (heading)
  "Insert section HEADING."
  (unless (bolp) (insert "\n"))
  (insert (propertize heading 'face 'beads-section-heading-face) "\n"))

(defun beads-show--insert-field (label value &optional face)
  "Insert LABEL and VALUE when VALUE is present, using optional FACE."
  (let ((text (beads-show--string value)))
    (unless (string-empty-p text)
      (insert (propertize (concat label ":") 'face 'bold) " ")
      (insert (if face (propertize text 'face face) text) "\n"))))

(defun beads-show--button-action (button)
  "Open the issue stored on BUTTON."
  (beads-show (button-get button 'beads-issue-id)
              (button-get button 'beads-workspace)))

(defun beads-show--insert-id-button (id &optional title)
  "Insert a button for issue ID with optional TITLE."
  (insert-text-button
   (if (and title (not (string-empty-p title)))
       (format "%s  %s" id title)
     id)
   'beads-issue-id id
   'beads-workspace beads-workspace
   'face 'beads-issue-id-face
   'follow-link t
   'help-echo (format "Open issue %s" id)
   'action #'beads-show--button-action))

(defun beads-show--insert-labels (labels)
  "Insert LABELS as a compact line."
  (when labels
    (insert (propertize "Labels:" 'face 'bold) " ")
    (insert (mapconcat #'beads-show--string labels ", ") "\n")))

(defun beads-show--insert-relations (heading relations)
  "Insert HEADING followed by issue RELATIONS."
  (when relations
    (beads-show--insert-heading heading)
    (dolist (relation relations)
      (insert "  • ")
      (beads-show--insert-id-button
       (beads-show--string (beads-object-get relation 'id))
       (beads-show--string (beads-object-get relation 'title)))
      (let ((type (beads-show--string
                   (beads-object-get relation 'dependency_type))))
        (unless (string-empty-p type)
          (insert (propertize (format "  [%s]" type) 'face 'beads-muted-face))))
      (insert "\n"))))

(defun beads-show--insert-text-section (heading text)
  "Insert HEADING and TEXT if TEXT is nonempty."
  (let ((text (beads-show--string text)))
    (unless (string-empty-p text)
      (beads-show--insert-heading heading)
      (insert text)
      (unless (bolp) (insert "\n")))))

(defun beads-show--status-face (status)
  "Return the appropriate face for STATUS."
  (pcase (beads-show--string status)
    ("closed" 'beads-status-closed-face)
    ("in_progress" 'beads-status-progress-face)
    ("blocked" 'beads-status-blocked-face)
    ("open" 'beads-status-open-face)
    (_ 'default)))

(defun beads-show--insert-comments (comments)
  "Insert issue COMMENTS."
  (when comments
    (beads-show--insert-heading "Comments")
    (dolist (comment comments)
      (let ((author (or (beads-object-get comment 'author)
                        (beads-object-get comment 'created_by)
                        "unknown"))
            (date (or (beads-object-get comment 'created_at) ""))
            (text (or (beads-object-get comment 'text)
                      (beads-object-get comment 'content)
                      (beads-object-get comment 'body)
                      "")))
        (insert (propertize (format "%s  %s" author date)
                            'face 'beads-muted-face)
                "  " (beads-show--string text) "\n\n")))))

(defun beads-show-render (issue)
  "Render normalized ISSUE in the current buffer."
  (let ((inhibit-read-only t)
        (point-position (point)))
    (erase-buffer)
    (let ((title (beads-show--string (beads-object-get issue 'title)))
          (id (beads-show--string (beads-object-get issue 'id))))
      (insert (propertize title 'face '(:height 1.35 :weight bold)) "\n")
      (insert (propertize id 'face 'beads-issue-id-face) "\n\n")
      (let ((status (beads-object-get issue 'status)))
        (beads-show--insert-field "Status" status
                                  (beads-show--status-face status)))
      (beads-show--insert-field
       "Priority"
       (let ((value (beads-object-get issue 'priority)))
         (and value (format "P%s" value))))
      (beads-show--insert-field "Type" (beads-object-get issue 'issue_type))
      (beads-show--insert-field "Assignee" (beads-object-get issue 'assignee))
      (beads-show--insert-field "Owner" (beads-object-get issue 'owner))
      (beads-show--insert-field "Due" (beads-object-get issue 'due_at))
      (beads-show--insert-field "Deferred until"
                                (or (beads-object-get issue 'defer_until)
                                    (beads-object-get issue 'deferred_until)))
      (beads-show--insert-labels (beads-object-get issue 'labels))
      (beads-show--insert-text-section "Description"
                                       (beads-object-get issue 'description))
      (beads-show--insert-text-section
       "Acceptance criteria" (beads-object-get issue 'acceptance_criteria))
      (beads-show--insert-text-section "Design" (beads-object-get issue 'design))
      (beads-show--insert-text-section "Notes" (beads-object-get issue 'notes))
      (beads-show--insert-relations "Depends on"
                                    (beads-object-get issue 'dependencies))
      (beads-show--insert-relations "Unblocks"
                                    (beads-object-get issue 'dependents))
      (beads-show--insert-comments (beads-object-get issue 'comments))
      (beads-show--insert-heading "History")
      (beads-show--insert-field "Created" (beads-object-get issue 'created_at))
      (beads-show--insert-field "Updated" (beads-object-get issue 'updated_at))
      (beads-show--insert-field "Closed" (beads-object-get issue 'closed_at))
      (goto-char (min point-position (point-max))))))

(defun beads-show--set-busy (busy)
  "Set the issue buffer BUSY indicator."
  (setq beads-show--busy busy
        mode-line-process
        (and busy '(" " (:propertize "loading" face warning))))
  (force-mode-line-update))

(defun beads-show-refresh ()
  "Refresh the issue in the current detail buffer."
  (interactive)
  (unless (and (derived-mode-p 'beads-show-mode) beads-show-id)
    (user-error "This is not a Beads issue buffer"))
  (let ((buffer (current-buffer)))
    (beads-show--set-busy t)
    (beads-br-async
     (list "show" beads-show-id "--json")
     (lambda (json)
       (let ((issues (beads-json-issues json)))
         (unless issues
           (signal 'beads-json-error (list "Show returned no issue")))
         (setq beads-show-issue (car issues))
         (beads-show--set-busy nil)
         (beads-show-render beads-show-issue)))
     (lambda (error-data)
       (beads-show--set-busy nil)
       (message "Could not load issue %s: %s" beads-show-id error-data))
     beads-workspace buffer)))

(defun beads-show--issue-candidates (workspace)
  "Return issue completion candidates from WORKSPACE.

Each candidate displays an issue ID and title while retaining the ID as its
value."
  (mapcar
   (lambda (issue)
     (let ((id (beads-show--string (beads-object-get issue 'id)))
           (title (beads-show--string (beads-object-get issue 'title))))
       (cons (if (string-empty-p title)
                 id
               (format "%s  %s" id title))
             id)))
   (beads-json-issues
    (beads-br-sync '("list" "--all" "--json") workspace))))

(defun beads-show--read-id (workspace)
  "Read an issue ID with completion from WORKSPACE."
  (let ((candidates (beads-show--issue-candidates workspace)))
    (unless candidates
      (user-error "No Beads issues found in %s" workspace))
    (let ((choice (completing-read "Issue: " candidates nil t)))
      (or (cdr (assoc choice candidates)) choice))))

;;;###autoload
(defun beads-show (id &optional workspace)
  "Display issue ID from WORKSPACE."
  (interactive
   (let ((root (beads-workspace-root)))
     (list (beads-show--read-id root) root)))
  (when (string-empty-p id)
    (user-error "Issue ID cannot be empty"))
  (let* ((root (beads-workspace-root workspace))
         (buffer (get-buffer-create beads-show-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'beads-show-mode)
        (beads-show-mode))
      (unless (and (equal beads-show-id id)
                   (equal beads-workspace root))
        (setq beads-show-issue nil)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Loading issue %s...\n" id))))
      (setq-local beads-workspace root)
      (setq-local beads-show-id id)
      (beads-watch-workspace #'beads-show-refresh)
      (beads-show-refresh))
    (pop-to-buffer buffer)
    buffer))

(provide 'beads-show)
;;; beads-show.el ends here
