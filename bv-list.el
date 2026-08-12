;;; bv-list.el --- Tabulated Beads issue lists  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Shared tabulated views for all, ready, blocked, and searched issues.

;;; Code:

(require 'cl-lib)
(require 'easymenu)
(require 'tabulated-list)
(require 'subr-x)
(require 'bv-core)

(defgroup bv-ui nil
  "User interface for Beads workspaces."
  :group 'bv)

(defface bv-priority-0-face
  '((t :inherit error :weight bold))
  "Face for critical (P0) issues."
  :group 'bv-ui)

(defface bv-priority-1-face
  '((t :inherit warning :weight bold))
  "Face for high-priority (P1) issues."
  :group 'bv-ui)

(defface bv-priority-2-face
  '((t :inherit font-lock-keyword-face))
  "Face for medium-priority (P2) issues."
  :group 'bv-ui)

(defface bv-priority-low-face
  '((t :inherit shadow))
  "Face for low-priority (P3 and P4) issues."
  :group 'bv-ui)

(defface bv-status-open-face
  '((t :inherit success))
  "Face for open issues."
  :group 'bv-ui)

(defface bv-status-progress-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for issues in progress."
  :group 'bv-ui)

(defface bv-status-blocked-face
  '((t :inherit error))
  "Face for blocked issues."
  :group 'bv-ui)

(defface bv-status-closed-face
  '((t :inherit shadow :strike-through t))
  "Face for closed issues."
  :group 'bv-ui)

(defface bv-issue-id-face
  '((t :inherit link :weight semi-bold))
  "Face for issue identifiers."
  :group 'bv-ui)

(defface bv-section-heading-face
  '((t :inherit font-lock-function-name-face :weight bold :height 1.1))
  "Face for headings in Beads buffers."
  :group 'bv-ui)

(defface bv-muted-face
  '((t :inherit shadow))
  "Face for secondary Beads information."
  :group 'bv-ui)

(declare-function bv-show "bv-show" (id &optional workspace))
(declare-function bv-create "bv-edit" (&optional workspace))
(declare-function bv-claim "bv-edit" (&optional id workspace))
(declare-function bv-close "bv-edit" (&optional id workspace))
(declare-function bv-reopen "bv-edit" (&optional id workspace))
(declare-function bv-update "bv-edit" (&optional id workspace))
(declare-function bv-menu "bv-transient" ())

(defvar bv-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'bv-list-show)
    (define-key map (kbd "o") #'bv-list-show)
    (define-key map (kbd "g") #'bv-list-refresh)
    (define-key map (kbd "a") #'bv-list-all)
    (define-key map (kbd "r") #'bv-list-ready)
    (define-key map (kbd "b") #'bv-list-blocked)
    (define-key map (kbd "/") #'bv-list-search)
    (define-key map (kbd "c") #'bv-create)
    (define-key map (kbd "C") #'bv-claim)
    (define-key map (kbd "e") #'bv-update)
    (define-key map (kbd "x") #'bv-close)
    (define-key map (kbd "R") #'bv-reopen)
    (define-key map (kbd "?") #'bv-menu)
    map)
  "Keymap for `bv-list-mode'.")

(easy-menu-define bv-list-mode-menu bv-list-mode-map
  "Menu for Beads issue lists."
  '("Beads"
    ["Show issue" bv-list-show :active (tabulated-list-get-id)]
    ["Refresh" bv-list-refresh t]
    "---"
    ["All issues" bv-list-all t]
    ["Ready issues" bv-list-ready t]
    ["Blocked issues" bv-list-blocked t]
    ["Search..." bv-list-search t]
    "---"
    ["Create issue..." bv-create t]
    ["Claim issue" bv-claim :active (tabulated-list-get-id)]
    ["Edit issue..." bv-update :active (tabulated-list-get-id)]
    ["Close issue..." bv-close :active (tabulated-list-get-id)]
    ["Reopen issue..." bv-reopen :active (tabulated-list-get-id)]
    "---"
    ["Command menu" bv-menu t]))

(defvar-local bv-list-kind 'all
  "Kind of issue query displayed in the current buffer.")

(defvar-local bv-list-query nil
  "Search query displayed in the current buffer, or nil.")

(defvar-local bv-list-issues nil
  "Normalized issues displayed in the current buffer.")

(defvar-local bv-list--refresh-generation 0
  "Generation number of the newest list refresh.")

(defvar-local bv-list--selected-id nil
  "Issue to restore after the current refresh.")

(defvar-local bv-list--busy nil
  "Non-nil while the list is being refreshed.")

(defun bv-list--object-get (object key &optional default)
  "Return KEY from OBJECT, or DEFAULT.

This wrapper makes the renderer convenient to exercise independently."
  (let ((value (bv-object-get object key)))
    (if (null value) default value)))

(defun bv-list--string (value)
  "Convert VALUE to a display string."
  (cond
   ((null value) "")
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%s" value))))

(defun bv-list--priority-string (issue)
  "Return the formatted priority for ISSUE."
  (let* ((raw (bv-list--object-get issue 'priority ""))
         (text (bv-list--string raw))
         (priority (if (string-prefix-p "P" text) text (concat "P" text)))
         (face (pcase priority
                 ("P0" 'bv-priority-0-face)
                 ("P1" 'bv-priority-1-face)
                 ("P2" 'bv-priority-2-face)
                 (_ 'bv-priority-low-face))))
    (propertize priority 'face face)))

(defun bv-list--status-string (issue)
  "Return the formatted status for ISSUE."
  (let* ((status (bv-list--string (bv-list--object-get issue 'status "")))
         (blocked-count
          (string-to-number
           (bv-list--string
            (bv-list--object-get issue 'blocked_by_count 0))))
         (blocked (or (equal bv-list-kind 'blocked)
                      (> blocked-count 0)))
         (face (cond
                (blocked 'bv-status-blocked-face)
                ((string= status "closed") 'bv-status-closed-face)
                ((string= status "in_progress") 'bv-status-progress-face)
                ((string= status "open") 'bv-status-open-face)
                (t 'default))))
    (propertize (replace-regexp-in-string "_" " " status) 'face face)))

(defun bv-list--entry (issue)
  "Convert ISSUE to a `tabulated-list-mode' entry."
  (let ((id (bv-list--string (bv-list--object-get issue 'id))))
    (list id
          (vector
           (bv-list--priority-string issue)
           (bv-list--status-string issue)
           (bv-list--string (bv-list--object-get issue 'issue_type))
           (propertize id 'face 'bv-issue-id-face)
           (bv-list--string (bv-list--object-get issue 'title))
           (bv-list--string (bv-list--object-get issue 'assignee))))))

(defun bv-list--entries ()
  "Return tabulated entries for `bv-list-issues'."
  (mapcar #'bv-list--entry bv-list-issues))

(define-derived-mode bv-list-mode tabulated-list-mode "Beads"
  "Major mode for browsing Beads issues."
  (setq tabulated-list-format
        [("Priority" 9 bv-list--sort-priority)
         ("Status" 13 t)
         ("Type" 10 t)
         ("ID" 28 t)
         ("Title" 48 t)
         ("Assignee" 18 t)])
  (setq tabulated-list-padding 2
        tabulated-list-entries #'bv-list--entries
        tabulated-list-sort-key '("Priority" . nil))
  (add-hook 'tabulated-list-revert-hook #'bv-list-refresh nil t)
  (tabulated-list-init-header))

(defun bv-list--sort-priority (a b)
  "Return non-nil when entry A has a lower priority number than B."
  (< (string-to-number (string-remove-prefix "P" (aref (cadr a) 0)))
     (string-to-number (string-remove-prefix "P" (aref (cadr b) 0)))))

(defun bv-list-current-id (&optional prompt)
  "Return the issue ID at point, prompting when needed if PROMPT is non-nil."
  (or (tabulated-list-get-id)
      (when prompt (read-string "Issue ID: "))))

(defun bv-list-show ()
  "Open the issue at point."
  (interactive)
  (let ((id (bv-list-current-id t)))
    (unless (string-empty-p id)
      (bv-show id bv-workspace))))

(defun bv-list--buffer-name (kind workspace &optional query)
  "Return a buffer name for KIND in WORKSPACE and optional QUERY."
  (format "*Beads %s: %s%s*"
          (capitalize (symbol-name kind))
          (file-name-nondirectory (directory-file-name workspace))
          (if query (format " — %s" query) "")))

(defun bv-list--args ()
  "Return the `br' arguments for the current list view."
  (pcase bv-list-kind
    ('all '("list" "--all" "--json"))
    ('ready '("ready" "--json"))
    ('blocked '("blocked" "--json"))
    ('search (list "search" (or bv-list-query "") "--json"))
    (_ (error "Unknown Beads list kind: %S" bv-list-kind))))

(defun bv-list--set-busy (busy)
  "Set current list buffer BUSY state."
  (setq bv-list--busy busy)
  (setq mode-line-process (and busy '(" " (:propertize "loading" face warning))))
  (force-mode-line-update))

(defun bv-list--restore-selection (id)
  "Move point to issue ID if it is present."
  (goto-char (point-min))
  (when id
    (unless (catch 'found
      (while (not (eobp))
        (when (equal (tabulated-list-get-id) id)
          (throw 'found t))
        (forward-line 1)))
      (goto-char (point-min)))))

(defun bv-list--success (buffer generation json)
  "Install JSON in BUFFER if GENERATION is current."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation bv-list--refresh-generation)
        (setq bv-list-issues (bv-json-issues json))
        (bv-list--set-busy nil)
        (tabulated-list-print t)
        (bv-list--restore-selection bv-list--selected-id)
        (setq header-line-format
              (format "%s issue%s"
                      (length bv-list-issues)
                      (if (= (length bv-list-issues) 1) "" "s")))))))

(defun bv-list--failure (buffer generation error-data)
  "Report ERROR-DATA for BUFFER if GENERATION is current."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation bv-list--refresh-generation)
        (bv-list--set-busy nil)
        (message "Beads refresh failed: %s" error-data)))))

(defun bv-list-refresh ()
  "Refresh the current issue list asynchronously."
  (interactive)
  (unless (derived-mode-p 'bv-list-mode)
    (user-error "This is not a Beads issue-list buffer"))
  (setq bv-list--selected-id (tabulated-list-get-id))
  (cl-incf bv-list--refresh-generation)
  (let ((buffer (current-buffer))
        (generation bv-list--refresh-generation))
    (bv-list--set-busy t)
    (bv-br-async (bv-list--args)
                 (lambda (json)
                   (bv-list--success buffer generation json))
                 (lambda (error-data)
                   (bv-list--failure buffer generation error-data))
                 bv-workspace buffer)))

(defun bv-list--open (kind &optional directory query)
  "Open a KIND list in DIRECTORY, optionally for search QUERY."
  (let* ((workspace (bv-workspace-root directory))
         (buffer (get-buffer-create
                  (bv-list--buffer-name kind workspace query))))
    (with-current-buffer buffer
      (bv-list-mode)
      (setq-local bv-workspace workspace)
      (setq-local bv-list-kind kind)
      (setq-local bv-list-query query)
      (setq-local revert-buffer-function
                  (lambda (&rest _ignored) (bv-list-refresh)))
      (bv-list-refresh))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun bv-list (&optional directory)
  "Open all Beads issues in DIRECTORY."
  (interactive)
  (bv-list--open 'all directory))

;;;###autoload
(defun bv-list-all (&optional directory)
  "Open all Beads issues in DIRECTORY."
  (interactive)
  (bv-list--open 'all (or directory bv-workspace)))

;;;###autoload
(defun bv-list-ready (&optional directory)
  "Open ready Beads issues in DIRECTORY."
  (interactive)
  (bv-list--open 'ready (or directory bv-workspace)))

;;;###autoload
(defalias 'bv-ready #'bv-list-ready)

;;;###autoload
(defun bv-list-blocked (&optional directory)
  "Open blocked Beads issues in DIRECTORY."
  (interactive)
  (bv-list--open 'blocked (or directory bv-workspace)))

;;;###autoload
(defalias 'bv-blocked #'bv-list-blocked)

;;;###autoload
(defun bv-list-search (query &optional directory)
  "Search for QUERY in the Beads workspace at DIRECTORY."
  (interactive (list (read-string "Search Beads: ") bv-workspace))
  (when (string-empty-p query)
    (user-error "Search text cannot be empty"))
  (bv-list--open 'search (or directory bv-workspace) query))

;;;###autoload
(defalias 'bv-search #'bv-list-search)

(provide 'bv-list)
;;; bv-list.el ends here
