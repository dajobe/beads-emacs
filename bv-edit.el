;;; bv-edit.el --- Edit Beads issues through br  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Dave Beckett <dave@dajobe.org>

;;; Commentary:

;; Guarded minibuffer workflows for mutating Beads issues.  Every command is
;; represented as an argv list and sent directly to `br'.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'bv-core)

(declare-function bv-list-refresh "bv-list" ())
(declare-function bv-show-refresh "bv-show" ())
(declare-function bv-triage-refresh "bv-triage" ())

(defconst bv-edit-priorities '("0" "1" "2" "3" "4")
  "Priority values accepted by br.")

(defconst bv-edit-types
  '("task" "bug" "feature" "epic" "chore" "docs" "question")
  "Common Beads issue types.")

(defconst bv-edit-statuses
  '("open" "in_progress" "blocked" "deferred")
  "Non-terminal Beads statuses accepted by `br update'.")

(defconst bv-edit-dependency-types
  '("blocks" "parent-child" "conditional-blocks" "waits-for" "related"
    "discovered-from" "replies-to" "relates-to" "duplicates" "supersedes"
    "caused-by")
  "Common Beads dependency types.")

(defun bv-edit--workspace (&optional workspace)
  "Return the active root, preferring explicit WORKSPACE."
  (bv-workspace-root (or workspace bv-workspace)))

(defun bv-edit--known-issues (workspace)
  "Return known issue objects in WORKSPACE."
  (bv-json-issues (bv-br-sync '("list" "--all" "--json") workspace)))

(defun bv-edit--issue-candidates (workspace)
  "Return completion candidates for issue IDs in WORKSPACE."
  (mapcar
   (lambda (issue)
     (let ((id (format "%s" (bv-object-get issue 'id)))
           (title (bv-object-get issue 'title "")))
       (cons (format "%s  %s" id title) id)))
   (bv-edit--known-issues workspace)))

(defun bv-edit--read-id (prompt workspace &optional omit-id)
  "Read an issue ID using PROMPT in WORKSPACE, omitting OMIT-ID."
  (let* ((candidates
          (seq-remove (lambda (candidate)
                        (equal (cdr candidate) omit-id))
                      (bv-edit--issue-candidates workspace)))
         (choice (completing-read prompt candidates nil nil)))
    (or (cdr (assoc choice candidates)) choice)))

(defun bv-edit-current-id (&optional prompt workspace)
  "Return the current issue ID, or ask using PROMPT in WORKSPACE."
  (or (and (boundp 'bv-show-id) bv-show-id)
      (and (derived-mode-p 'tabulated-list-mode)
           (tabulated-list-get-id))
      (bv-edit--read-id (or prompt "Issue: ")
                        (bv-edit--workspace workspace))))

(defun bv-edit--refresh-workspace (workspace)
  "Refresh live Beads UI buffers belonging to WORKSPACE."
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (bound-and-true-p bv-workspace)
                   (equal (file-truename bv-workspace)
                          (file-truename workspace)))
          (cond
           ((derived-mode-p 'bv-list-mode) (bv-list-refresh))
           ((derived-mode-p 'bv-show-mode) (bv-show-refresh))
           ((derived-mode-p 'bv-triage-mode) (bv-triage-refresh))))))))

(defun bv-edit--error-message (data)
  "Return a concise message for command error DATA."
  (string-trim
   (or (plist-get data :stderr)
       (plist-get data :message)
       (format "%s" data))))

(defun bv-edit--mutate (arguments workspace action &optional callback)
  "Run br ARGUMENTS in WORKSPACE and report ACTION.

Call CALLBACK with decoded JSON after success, then refresh matching UI
buffers."
  (let ((origin (current-buffer)))
    (message "%s..." action)
    (bv-br-async
     arguments
     (lambda (json)
       (message "%s" action)
       (when callback (funcall callback json))
       (bv-edit--refresh-workspace workspace))
     (lambda (data)
       (message "%s failed: %s" action (bv-edit--error-message data)))
     workspace origin)))

(defun bv-edit--read-choice (prompt choices &optional default)
  "Read one of CHOICES with PROMPT and optional DEFAULT."
  (completing-read prompt choices nil t nil nil default))

(defun bv-edit--read-issue (id workspace)
  "Read issue ID synchronously from WORKSPACE."
  (car (bv-json-issues
        (bv-br-sync (list "show" id "--json") workspace))))

;;;###autoload
(defun bv-create (&optional workspace)
  "Create a Beads issue in WORKSPACE."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (title (string-trim (read-string "Title: ")))
         (type (bv-edit--read-choice "Type: " bv-edit-types "task"))
         (priority (bv-edit--read-choice
                    "Priority (0 highest): " bv-edit-priorities "2"))
         (description (read-string "Description (optional): "))
         (arguments (append (list "create" title "--type" type
                                  "--priority" priority)
                            (unless (string-empty-p description)
                              (list "--description" description))
                            '("--json"))))
    (when (string-empty-p title)
      (user-error "Title cannot be empty"))
    (bv-edit--mutate
     arguments workspace "Created issue"
     (lambda (json)
       (let* ((issues (ignore-errors (bv-json-issues json)))
              (id (and issues (bv-object-get (car issues) 'id))))
         (when id (message "Created issue %s" id)))))))

;;;###autoload
(defun bv-update (&optional id workspace)
  "Update a field on issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (id (or id (bv-edit-current-id "Update issue: " workspace)))
         (issue (bv-edit--read-issue id workspace))
         (field (bv-edit--read-choice
                 "Field: "
                 '("title" "description" "status" "priority" "type"
                   "assignee" "due" "estimate")))
         (current (bv-object-get
                   issue (pcase field
                           ("type" 'issue_type)
                           ("due" 'due_at)
                           (_ field))
                   ""))
         (value
          (pcase field
            ("status" (bv-edit--read-choice
                       "Status: " bv-edit-statuses (format "%s" current)))
            ("priority" (bv-edit--read-choice
                         "Priority: " bv-edit-priorities
                         (format "%s" current)))
            ("type" (bv-edit--read-choice
                     "Type: " bv-edit-types (format "%s" current)))
            (_ (read-string (format "%s: " (capitalize field))
                            (format "%s" current)))))
         (flag (pcase field
                 ("type" "--type")
                 (_ (concat "--" field)))))
    (bv-edit--mutate (list "update" id flag value "--json")
                     workspace (format "Updated %s" id))))

;;;###autoload
(defun bv-claim (&optional id workspace)
  "Atomically claim issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (id (or id (bv-edit-current-id "Claim issue: " workspace))))
    (bv-edit--mutate (list "update" id "--claim" "--json")
                     workspace (format "Claimed %s" id))))

;;;###autoload
(defun bv-close (&optional id workspace)
  "Close issue ID in WORKSPACE after confirmation."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (id (or id (bv-edit-current-id "Close issue: " workspace)))
         (reason (string-trim (read-string "Close reason: "))))
    (unless (y-or-n-p (format "Close %s? " id))
      (user-error "Close cancelled"))
    (bv-edit--mutate
     (append (list "close" id)
             (unless (string-empty-p reason) (list "--reason" reason))
             '("--json"))
     workspace (format "Closed %s" id))))

;;;###autoload
(defun bv-reopen (&optional id workspace)
  "Reopen issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (id (or id (bv-edit-current-id "Reopen issue: " workspace)))
         (reason (string-trim (read-string "Reopen reason (optional): "))))
    (bv-edit--mutate
     (append (list "reopen" id)
             (unless (string-empty-p reason) (list "--reason" reason))
             '("--json"))
     workspace (format "Reopened %s" id))))

;;;###autoload
(defun bv-defer (&optional id workspace)
  "Defer issue ID until a date or relative time in WORKSPACE."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (id (or id (bv-edit-current-id "Defer issue: " workspace)))
         (until (string-trim
                 (read-string "Defer until (date, tomorrow, +1w): "))))
    (when (string-empty-p until)
      (user-error "A defer time is required"))
    (bv-edit--mutate (list "defer" id "--until" until "--json")
                     workspace (format "Deferred %s" id))))

;;;###autoload
(defun bv-undefer (&optional id workspace)
  "Remove the defer date from issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (id (or id (bv-edit-current-id "Undefer issue: " workspace))))
    (bv-edit--mutate (list "undefer" id "--json")
                     workspace (format "Undeferred %s" id))))

;;;###autoload
(defun bv-add-comment (&optional id workspace)
  "Add a comment to issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (id (or id (bv-edit-current-id "Comment on issue: " workspace)))
         (text (string-trim (read-string "Comment: "))))
    (when (string-empty-p text)
      (user-error "Comment cannot be empty"))
    (bv-edit--mutate
     (list "comments" "add" id "--message" text "--json")
     workspace (format "Commented on %s" id))))

(defun bv-edit--labels (workspace)
  "Return label names known in WORKSPACE."
  (let ((json (bv-br-sync '("label" "list-all" "--json") workspace)))
    (delete-dups
     (delq nil
           (mapcar (lambda (item)
                     (cond
                      ((stringp item) item)
                      ((listp item)
                       (or (bv-object-get item 'label)
                           (bv-object-get item 'name)))
                      (t nil)))
                   (or (bv-object-get json 'labels) json))))))

;;;###autoload
(defun bv-add-label (&optional id workspace)
  "Add a label to issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (id (or id (bv-edit-current-id "Label issue: " workspace)))
         (label (completing-read "Add label: "
                                 (bv-edit--labels workspace) nil nil)))
    (when (string-empty-p label)
      (user-error "Label cannot be empty"))
    (bv-edit--mutate
     (list "label" "add" id "--label" label "--json")
     workspace (format "Added label to %s" id))))

;;;###autoload
(defun bv-remove-label (&optional id workspace)
  "Remove a label from issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (id (or id (bv-edit-current-id "Unlabel issue: " workspace)))
         (issue (bv-edit--read-issue id workspace))
         (labels (bv-object-get issue 'labels))
         (label (completing-read "Remove label: " labels nil t)))
    (bv-edit--mutate
     (list "label" "remove" id "--label" label "--json")
     workspace (format "Removed label from %s" id))))

;;;###autoload
(defun bv-add-dependency (&optional id workspace)
  "Make issue ID depend on another issue in WORKSPACE."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (id (or id (bv-edit-current-id "Issue: " workspace)))
         (target (bv-edit--read-id "Depends on: " workspace id))
         (type (bv-edit--read-choice
                "Dependency type: " bv-edit-dependency-types "blocks")))
    (bv-edit--mutate
     (list "dep" "add" id target "--type" type "--json")
     workspace (format "Added dependency to %s" id))))

;;;###autoload
(defun bv-remove-dependency (&optional id workspace)
  "Remove one dependency from issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (bv-edit--workspace workspace))
         (id (or id (bv-edit-current-id "Issue: " workspace)))
         (issue (bv-edit--read-issue id workspace))
         (relations (bv-object-get issue 'dependencies))
         (candidates
          (mapcar (lambda (relation)
                    (let ((other (format "%s" (bv-object-get relation 'id)))
                          (title (bv-object-get relation 'title "")))
                      (cons (format "%s  %s" other title) other)))
                  relations))
         (choice (completing-read "Remove dependency: "
                                  candidates nil t))
         (target (cdr (assoc choice candidates))))
    (unless target
      (user-error "Issue %s has no selectable dependency" id))
    (when (y-or-n-p (format "Remove dependency %s -> %s? " id target))
      (bv-edit--mutate (list "dep" "remove" id target "--json")
                       workspace (format "Removed dependency from %s" id)))))

(provide 'bv-edit)
;;; bv-edit.el ends here
