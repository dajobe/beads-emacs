;;; beads-edit.el --- Edit Beads issues through br  -*- lexical-binding: t; -*-

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
(require 'beads-core)

(declare-function beads-list-refresh "beads-list" ())
(declare-function beads-show-refresh "beads-show" ())
(declare-function beads-triage-refresh "beads-triage" ())

(defconst beads-edit-priorities '("0" "1" "2" "3" "4")
  "Priority values accepted by br.")

(defconst beads-edit-types
  '("task" "bug" "feature" "epic" "chore" "docs" "question")
  "Common Beads issue types.")

(defconst beads-edit-statuses
  '("open" "in_progress" "blocked" "deferred")
  "Non-terminal Beads statuses accepted by `br update'.")

(defconst beads-edit-dependency-types
  '("blocks" "parent-child" "conditional-blocks" "waits-for" "related"
    "discovered-from" "replies-to" "relates-to" "duplicates" "supersedes"
    "caused-by")
  "Common Beads dependency types.")

(defun beads-edit--workspace (&optional workspace)
  "Return the active root, preferring explicit WORKSPACE."
  (beads-workspace-root (or workspace beads-workspace)))

(defun beads-edit--known-issues (workspace)
  "Return known issue objects in WORKSPACE."
  (beads-json-issues (beads-br-sync '("list" "--all" "--json") workspace)))

(defun beads-edit--issue-candidates (workspace)
  "Return completion candidates for issue IDs in WORKSPACE."
  (mapcar
   (lambda (issue)
     (let ((id (format "%s" (beads-object-get issue 'id)))
           (title (beads-object-get issue 'title "")))
       (cons (format "%s  %s" id title) id)))
   (beads-edit--known-issues workspace)))

(defun beads-edit--read-id (prompt workspace &optional omit-id)
  "Read an issue ID using PROMPT in WORKSPACE, omitting OMIT-ID."
  (let* ((candidates
          (seq-remove (lambda (candidate)
                        (equal (cdr candidate) omit-id))
                      (beads-edit--issue-candidates workspace)))
         (choice (completing-read prompt candidates nil nil)))
    (or (cdr (assoc choice candidates)) choice)))

(defun beads-edit-current-id (&optional prompt workspace)
  "Return the current issue ID, or ask using PROMPT in WORKSPACE."
  (or (and (boundp 'beads-show-id) beads-show-id)
      (and (derived-mode-p 'tabulated-list-mode)
           (tabulated-list-get-id))
      (beads-edit--read-id (or prompt "Issue: ")
                           (beads-edit--workspace workspace))))

(defun beads-edit--refresh-workspace (workspace)
  "Refresh live Beads UI buffers belonging to WORKSPACE."
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (bound-and-true-p beads-workspace)
                   (equal (file-truename beads-workspace)
                          (file-truename workspace)))
          (cond
           ((derived-mode-p 'beads-list-mode) (beads-list-refresh))
           ((derived-mode-p 'beads-show-mode) (beads-show-refresh))
           ((derived-mode-p 'beads-triage-mode) (beads-triage-refresh))))))))

(defun beads-edit--error-message (data)
  "Return a concise message for command error DATA."
  (string-trim
   (or (plist-get data :stderr)
       (plist-get data :message)
       (format "%s" data))))

(defun beads-edit--mutate (arguments workspace action &optional callback)
  "Run br ARGUMENTS in WORKSPACE and report ACTION.

Call CALLBACK with decoded JSON after success, then refresh matching UI
buffers."
  (let ((origin (current-buffer)))
    (message "%s..." action)
    (beads-br-async
     arguments
     (lambda (json)
       (message "%s" action)
       (when callback (funcall callback json))
       (beads-edit--refresh-workspace workspace))
     (lambda (data)
       (message "%s failed: %s" action (beads-edit--error-message data)))
     workspace origin)))

(defun beads-edit--read-choice (prompt choices &optional default)
  "Read one of CHOICES with PROMPT and optional DEFAULT."
  (completing-read prompt choices nil t nil nil default))

(defun beads-edit--read-issue (id workspace)
  "Read issue ID synchronously from WORKSPACE."
  (car (beads-json-issues
        (beads-br-sync (list "show" id "--json") workspace))))

;;;###autoload
(defun beads-create (&optional workspace)
  "Create a Beads issue in WORKSPACE."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (title (string-trim (read-string "Title: ")))
         (type (beads-edit--read-choice "Type: " beads-edit-types "task"))
         (priority (beads-edit--read-choice
                    "Priority (0 highest): " beads-edit-priorities "2"))
         (description (read-string "Description (optional): "))
         (arguments (append (list "create" title "--type" type
                                  "--priority" priority)
                            (unless (string-empty-p description)
                              (list "--description" description))
                            '("--json"))))
    (when (string-empty-p title)
      (user-error "Title cannot be empty"))
    (beads-edit--mutate
     arguments workspace "Created issue"
     (lambda (json)
       (let* ((issues (ignore-errors (beads-json-issues json)))
              (id (and issues (beads-object-get (car issues) 'id))))
         (when id (message "Created issue %s" id)))))))

;;;###autoload
(defun beads-update (&optional id workspace)
  "Update a field on issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (id (or id (beads-edit-current-id "Update issue: " workspace)))
         (issue (beads-edit--read-issue id workspace))
         (field (beads-edit--read-choice
                 "Field: "
                 '("title" "description" "status" "priority" "type"
                   "assignee" "due" "estimate")))
         (current (beads-object-get
                   issue (pcase field
                           ("type" 'issue_type)
                           ("due" 'due_at)
                           (_ field))
                   ""))
         (value
          (pcase field
            ("status" (beads-edit--read-choice
                       "Status: " beads-edit-statuses (format "%s" current)))
            ("priority" (beads-edit--read-choice
                         "Priority: " beads-edit-priorities
                         (format "%s" current)))
            ("type" (beads-edit--read-choice
                     "Type: " beads-edit-types (format "%s" current)))
            (_ (read-string (format "%s: " (capitalize field))
                            (format "%s" current)))))
         (flag (pcase field
                 ("type" "--type")
                 (_ (concat "--" field)))))
    (beads-edit--mutate (list "update" id flag value "--json")
                        workspace (format "Updated %s" id))))

;;;###autoload
(defun beads-claim (&optional id workspace)
  "Atomically claim issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (id (or id (beads-edit-current-id "Claim issue: " workspace))))
    (beads-edit--mutate (list "update" id "--claim" "--json")
                        workspace (format "Claimed %s" id))))

;;;###autoload
(defun beads-close (&optional id workspace)
  "Close issue ID in WORKSPACE after confirmation."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (id (or id (beads-edit-current-id "Close issue: " workspace)))
         (reason (string-trim (read-string "Close reason: "))))
    (unless (y-or-n-p (format "Close %s? " id))
      (user-error "Close cancelled"))
    (beads-edit--mutate
     (append (list "close" id)
             (unless (string-empty-p reason) (list "--reason" reason))
             '("--json"))
     workspace (format "Closed %s" id))))

;;;###autoload
(defun beads-reopen (&optional id workspace)
  "Reopen issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (id (or id (beads-edit-current-id "Reopen issue: " workspace)))
         (reason (string-trim (read-string "Reopen reason (optional): "))))
    (beads-edit--mutate
     (append (list "reopen" id)
             (unless (string-empty-p reason) (list "--reason" reason))
             '("--json"))
     workspace (format "Reopened %s" id))))

;;;###autoload
(defun beads-defer (&optional id workspace)
  "Defer issue ID until a date or relative time in WORKSPACE."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (id (or id (beads-edit-current-id "Defer issue: " workspace)))
         (until (string-trim
                 (read-string "Defer until (date, tomorrow, +1w): "))))
    (when (string-empty-p until)
      (user-error "A defer time is required"))
    (beads-edit--mutate (list "defer" id "--until" until "--json")
                        workspace (format "Deferred %s" id))))

;;;###autoload
(defun beads-undefer (&optional id workspace)
  "Remove the defer date from issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (id (or id (beads-edit-current-id "Undefer issue: " workspace))))
    (beads-edit--mutate (list "undefer" id "--json")
                        workspace (format "Undeferred %s" id))))

;;;###autoload
(defun beads-add-comment (&optional id workspace)
  "Add a comment to issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (id (or id (beads-edit-current-id "Comment on issue: " workspace)))
         (text (string-trim (read-string "Comment: "))))
    (when (string-empty-p text)
      (user-error "Comment cannot be empty"))
    (beads-edit--mutate
     (list "comments" "add" id "--message" text "--json")
     workspace (format "Commented on %s" id))))

(defun beads-edit--labels (workspace)
  "Return label names known in WORKSPACE."
  (let ((json (beads-br-sync '("label" "list-all" "--json") workspace)))
    (delete-dups
     (delq nil
           (mapcar (lambda (item)
                     (cond
                      ((stringp item) item)
                      ((listp item)
                       (or (beads-object-get item 'label)
                           (beads-object-get item 'name)))
                      (t nil)))
                   (or (beads-object-get json 'labels) json))))))

;;;###autoload
(defun beads-add-label (&optional id workspace)
  "Add a label to issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (id (or id (beads-edit-current-id "Label issue: " workspace)))
         (label (completing-read "Add label: "
                                 (beads-edit--labels workspace) nil nil)))
    (when (string-empty-p label)
      (user-error "Label cannot be empty"))
    (beads-edit--mutate
     (list "label" "add" id "--label" label "--json")
     workspace (format "Added label to %s" id))))

;;;###autoload
(defun beads-remove-label (&optional id workspace)
  "Remove a label from issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (id (or id (beads-edit-current-id "Unlabel issue: " workspace)))
         (issue (beads-edit--read-issue id workspace))
         (labels (beads-object-get issue 'labels))
         (label (completing-read "Remove label: " labels nil t)))
    (beads-edit--mutate
     (list "label" "remove" id "--label" label "--json")
     workspace (format "Removed label from %s" id))))

;;;###autoload
(defun beads-add-dependency (&optional id workspace)
  "Make issue ID depend on another issue in WORKSPACE."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (id (or id (beads-edit-current-id "Issue: " workspace)))
         (target (beads-edit--read-id "Depends on: " workspace id))
         (type (beads-edit--read-choice
                "Dependency type: " beads-edit-dependency-types "blocks")))
    (beads-edit--mutate
     (list "dep" "add" id target "--type" type "--json")
     workspace (format "Added dependency to %s" id))))

;;;###autoload
(defun beads-remove-dependency (&optional id workspace)
  "Remove one dependency from issue ID in WORKSPACE."
  (interactive)
  (let* ((workspace (beads-edit--workspace workspace))
         (id (or id (beads-edit-current-id "Issue: " workspace)))
         (issue (beads-edit--read-issue id workspace))
         (relations (beads-object-get issue 'dependencies))
         (candidates
          (mapcar (lambda (relation)
                    (let ((other (format "%s" (beads-object-get relation 'id)))
                          (title (beads-object-get relation 'title "")))
                      (cons (format "%s  %s" other title) other)))
                  relations))
         (choice (completing-read "Remove dependency: "
                                  candidates nil t))
         (target (cdr (assoc choice candidates))))
    (unless target
      (user-error "Issue %s has no selectable dependency" id))
    (when (y-or-n-p (format "Remove dependency %s -> %s? " id target))
      (beads-edit--mutate (list "dep" "remove" id target "--json")
                          workspace (format "Removed dependency from %s" id)))))

(provide 'beads-edit)
;;; beads-edit.el ends here
