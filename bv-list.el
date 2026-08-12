;;; bv-list.el --- Tabulated Beads issue lists  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Shared tabulated views and in-place filters for Beads issues.

;;; Code:

(require 'cl-lib)
(require 'easymenu)
(require 'parse-time)
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
    (define-key map (kbd "g") #'bv-list-refresh)
    (define-key map (kbd "a") #'bv-list-all)
    (define-key map (kbd "o") #'bv-list-open)
    (define-key map (kbd "c") #'bv-list-closed)
    (define-key map (kbd "r") #'bv-list-ready)
    (define-key map (kbd "b") #'bv-list-blocked)
    (define-key map (kbd "l") #'bv-list-label)
    (define-key map (kbd "/") #'bv-list-search)
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
    ["Open issues" bv-list-open t]
    ["Closed issues" bv-list-closed t]
    ["Ready issues" bv-list-ready t]
    ["Blocked issues" bv-list-blocked t]
    ["Filter by label..." bv-list-label t]
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

(defvar-local bv-list--displayed-width nil
  "Window width used for the most recent responsive row rendering.")

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

(defun bv-list--type-icon (issue)
  "Return a type icon with explanatory text for ISSUE."
  (let* ((type (bv-list--string (bv-list--object-get issue 'issue_type)))
         (icon (pcase type
                 ("bug" "🐛")
                 ("feature" "✨")
                 ("task" "📋")
                 ("epic" "🚀")
                 ("chore" "🧹")
                 (_ "•"))))
    (propertize icon 'help-echo
                (format "Type: %s" (if (string-empty-p type) "unknown" type)))))

(defun bv-list--status-string (issue)
  "Return the compact formatted status for ISSUE."
  (let* ((status (bv-list--string (bv-list--object-get issue 'status "")))
         (blocked-count
          (string-to-number
           (bv-list--string
            (bv-list--object-get issue 'blocked_by_count 0))))
         (blocked (or (string= status "blocked")
                      (equal bv-list-kind 'blocked)
                      (> blocked-count 0)))
         (label (if blocked
                    "BLKD"
                  (pcase status
                    ("open" "OPEN")
                    ("in_progress" "PROG")
                    ("closed" "DONE")
                    ("deferred" "DEFR")
                    ("draft" "DRFT")
                    ("pinned" "PIN")
                    ("hooked" "HOOK")
                    ("review" "REVW")
                    ("tombstone" "TOMB")
                    (_ "????"))))
         (face (cond
                (blocked 'bv-status-blocked-face)
                ((string= status "closed") 'bv-status-closed-face)
                ((string= status "in_progress") 'bv-status-progress-face)
                ((string= status "open") 'bv-status-open-face)
                (t 'default))))
    (propertize label 'face face 'help-echo (format "Status: %s" status))))

(defun bv-list--relative-time (timestamp &optional now)
  "Return TIMESTAMP relative to NOW in the compact `bv' style."
  (let ((text (bv-list--string timestamp))
        (unknown "unknown"))
    (if (not
         (string-match-p
          (rx string-start
              (= 4 digit) "-" (= 2 digit) "-" (= 2 digit) "T"
              (= 2 digit) ":" (= 2 digit) ":" (= 2 digit)
              (optional "." (+ digit))
              (or "Z" (seq (any "+-") (= 2 digit) ":" (= 2 digit)))
              string-end)
          text))
        unknown
      (condition-case nil
          (let ((seconds
                 (float-time
                  (time-subtract (or now (current-time))
                                 (parse-iso8601-time-string text)))))
            (cond
             ((< seconds 60) "now")
             ((< seconds 3600) (format "%dm ago" (floor (/ seconds 60))))
             ((< seconds 86400) (format "%dh ago" (floor (/ seconds 3600))))
             ((< seconds 604800) (format "%dd ago" (floor (/ seconds 86400))))
             ((< seconds 2592000)
              (format "%dw ago" (floor (/ seconds 604800))))
             (t (format "%dmo ago" (floor (/ seconds 2592000))))))
        (error unknown)))))

(defun bv-list--age-string (issue)
  "Return a muted relative creation age for ISSUE."
  (let* ((timestamp (or (bv-list--object-get issue 'created_at)
                        (bv-list--object-get issue 'updated_at)))
         (age (bv-list--relative-time timestamp)))
    (propertize age 'face 'bv-muted-face
                'help-echo (if timestamp
                               (format "Created: %s" timestamp)
                             "Creation time unknown"))))

(defun bv-list--entry (issue)
  "Convert ISSUE to a `tabulated-list-mode' entry."
  (let ((id (bv-list--string (bv-list--object-get issue 'id))))
    (list id
          (vector
           (bv-list--type-icon issue)
           (bv-list--priority-string issue)
           (bv-list--status-string issue)
           (propertize id 'face 'bv-issue-id-face)
           (bv-list--string (bv-list--object-get issue 'title))
           (bv-list--age-string issue)))))

(defun bv-list--entries ()
  "Return tabulated entries for `bv-list-issues'."
  (mapcar #'bv-list--entry bv-list-issues))

(defun bv-list--display-width ()
  "Return the usable display width for the current list buffer."
  (if-let* ((window (get-buffer-window (current-buffer) t)))
      (window-body-width window)
    80))

(defun bv-list--truncate (text width)
  "Truncate TEXT to display WIDTH with an ellipsis."
  (if (<= width 0)
      ""
    (truncate-string-to-width text width nil nil "…")))

(defun bv-list--print-entry (id columns)
  "Insert responsive list entry ID described by COLUMNS."
  (let* ((inhibit-read-only t)
         (beg (point))
         (icon (aref columns 0))
         (priority (aref columns 1))
         (status (aref columns 2))
         (issue-id (aref columns 3))
         (title (aref columns 4))
         (age (aref columns 5))
         (age-width 8)
         (width (max 24 (bv-list--display-width)))
         (fixed-prefix (concat "  " icon " " priority " " status " "))
         (minimum-title-width 8)
         (id-budget (max 8 (- width (string-width fixed-prefix)
                              age-width minimum-title-width 2)))
         (visible-id (bv-list--truncate issue-id id-budget))
         (prefix (concat fixed-prefix visible-id " "))
         (title-width (max 0 (- width (string-width prefix) age-width 1)))
         (visible-title (bv-list--truncate title title-width)))
    (insert prefix visible-title)
    (insert (propertize " " 'display
                        `(space :align-to (- right-fringe ,age-width))))
    (insert (format (format "%%%ds" age-width) age) "\n")
    (add-text-properties
     beg (point)
     `(tabulated-list-id ,id tabulated-list-entry ,columns))))

(define-derived-mode bv-list-mode tabulated-list-mode "Beads"
  "Major mode for browsing Beads issues."
  (setq tabulated-list-format
        [("Type" 3 t)
         ("Priority" 3 bv-list--sort-priority)
         ("Status" 5 t)
         ("ID" 28 t)
         ("Title" 48 t)
         ("Age" 8 t :right-align t)])
  (setq tabulated-list-padding 0
        tabulated-list-entries #'bv-list--entries
        tabulated-list-printer #'bv-list--print-entry
        tabulated-list-sort-key '("Priority" . nil))
  (add-hook 'tabulated-list-revert-hook #'bv-list-refresh nil t)
  (add-hook 'window-size-change-functions
            #'bv-list--window-size-change nil t)
  (tabulated-list-init-header))

(defun bv-list--sort-priority (a b)
  "Return non-nil when entry A has a lower priority number than B."
  (< (string-to-number (string-remove-prefix "P" (aref (cadr a) 1)))
     (string-to-number (string-remove-prefix "P" (aref (cadr b) 1)))))

(defun bv-list--window-size-change (window)
  "Redisplay list rows after a width change in WINDOW."
  (let ((buffer (window-buffer window)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'bv-list-mode)
          (let ((width (window-body-width window)))
            (unless (equal width bv-list--displayed-width)
              (setq bv-list--displayed-width width
                    bv-list--selected-id (tabulated-list-get-id))
              (tabulated-list-print t)
              (bv-list--restore-selection bv-list--selected-id))))))))

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

(defun bv-list--view-title ()
  "Return a display title for the current list view."
  (pcase bv-list-kind
    ('all "All")
    ('open "Open")
    ('closed "Closed")
    ('ready "Ready")
    ('blocked "Blocked")
    ('label (format "Label: %s" bv-list-query))
    ('search (format "Search: %s" bv-list-query))
    (_ (capitalize (symbol-name bv-list-kind)))))

(defun bv-list--header-line ()
  "Return a responsive header for the current issue list."
  (list (format "%s — %s issue%s    TYPE PRI STATUS ID TITLE"
                (bv-list--view-title)
                (length bv-list-issues)
                (if (= (length bv-list-issues) 1) "" "s"))
        (propertize " " 'display '(space :align-to (- right-fringe 3)))
        "AGE"))

(defun bv-list--args ()
  "Return the `br' arguments for the current list view."
  (pcase bv-list-kind
    ('all '("list" "--all" "--json"))
    ('open '("list" "--status" "open" "--json"))
    ('closed '("list" "--status" "closed" "--json"))
    ('ready '("ready" "--json"))
    ('blocked '("blocked" "--json"))
    ('label (list "list" "--all" "--label"
                  (or bv-list-query "") "--json"))
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
        (setq bv-list--displayed-width (bv-list--display-width))
        (tabulated-list-print t)
        (bv-list--restore-selection bv-list--selected-id)
        (setq header-line-format (bv-list--header-line))))))

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
      (bv-watch-workspace #'bv-list-refresh)
      (bv-list-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun bv-list--switch (kind &optional query)
  "Switch the current list buffer to KIND and optional QUERY."
  (unless (derived-mode-p 'bv-list-mode)
    (user-error "This is not a Beads issue-list buffer"))
  (setq bv-list-kind kind
        bv-list-query query)
  (rename-buffer (bv-list--buffer-name kind bv-workspace query) t)
  (bv-list-refresh)
  (current-buffer))

(defun bv-list--visit (kind &optional directory query)
  "Switch to or open a KIND list in DIRECTORY with optional QUERY."
  (if (and (derived-mode-p 'bv-list-mode)
           (or (null directory)
               (equal bv-workspace
                      (let ((bv-workspace nil))
                        (bv-workspace-root directory)))))
      (bv-list--switch kind query)
    (bv-list--open kind directory query)))

(defun bv-list--known-labels (workspace)
  "Return sorted issue labels found in WORKSPACE."
  (let (result)
    (dolist (issue (bv-json-issues
                    (bv-br-sync '("list" "--all" "--json") workspace)))
      (let ((labels (bv-object-get issue 'labels)))
        (dolist (label (cond
                        ((vectorp labels) (append labels nil))
                        ((listp labels) labels)))
          (when (and (stringp label) (not (string-empty-p label)))
            (cl-pushnew label result :test #'equal)))))
    (sort result #'string-lessp)))

(defun bv-list--read-label (workspace)
  "Read an existing issue label from WORKSPACE."
  (let ((labels (bv-list--known-labels workspace)))
    (unless labels
      (user-error "No Beads labels found in %s" workspace))
    (completing-read "Label: " labels nil t)))

;;;###autoload
(defun bv-list (&optional directory)
  "Open all Beads issues in DIRECTORY."
  (interactive)
  (bv-list--visit 'all directory))

;;;###autoload
(defun bv-list-all (&optional directory)
  "Show all Beads issues in DIRECTORY."
  (interactive)
  (bv-list--visit 'all directory))

;;;###autoload
(defun bv-list-open (&optional directory)
  "Show open Beads issues in DIRECTORY."
  (interactive)
  (bv-list--visit 'open directory))

;;;###autoload
(defun bv-list-closed (&optional directory)
  "Show closed Beads issues in DIRECTORY."
  (interactive)
  (bv-list--visit 'closed directory))

;;;###autoload
(defun bv-list-ready (&optional directory)
  "Show ready Beads issues in DIRECTORY."
  (interactive)
  (bv-list--visit 'ready directory))

;;;###autoload
(defalias 'bv-ready #'bv-list-ready)

;;;###autoload
(defun bv-list-blocked (&optional directory)
  "Show blocked Beads issues in DIRECTORY."
  (interactive)
  (bv-list--visit 'blocked directory))

;;;###autoload
(defalias 'bv-blocked #'bv-list-blocked)

;;;###autoload
(defun bv-list-label (label &optional directory)
  "Show issues with LABEL in the Beads workspace at DIRECTORY."
  (interactive
   (let ((workspace (bv-workspace-root)))
     (list (bv-list--read-label workspace) nil)))
  (when (string-empty-p label)
    (user-error "Label cannot be empty"))
  (bv-list--visit 'label directory label))

;;;###autoload
(defun bv-list-search (query &optional directory)
  "Search for QUERY in the Beads workspace at DIRECTORY."
  (interactive (list (read-string "Search Beads: ") bv-workspace))
  (when (string-empty-p query)
    (user-error "Search text cannot be empty"))
  (bv-list--visit 'search directory query))

;;;###autoload
(defalias 'bv-search #'bv-list-search)

(provide 'bv-list)
;;; bv-list.el ends here
