;;; beads-list.el --- Tabulated Beads issue lists  -*- lexical-binding: t; -*-

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
(require 'beads-core)

(defgroup beads-ui nil
  "User interface for Beads workspaces."
  :group 'beads)

(defface beads-priority-0-face
  '((t :inherit error :weight bold))
  "Face for critical (P0) issues."
  :group 'beads-ui)

(defface beads-priority-1-face
  '((t :inherit warning :weight bold))
  "Face for high-priority (P1) issues."
  :group 'beads-ui)

(defface beads-priority-2-face
  '((t :inherit font-lock-keyword-face))
  "Face for medium-priority (P2) issues."
  :group 'beads-ui)

(defface beads-priority-low-face
  '((t :inherit shadow))
  "Face for low-priority (P3 and P4) issues."
  :group 'beads-ui)

(defface beads-status-open-face
  '((t :inherit success))
  "Face for open issues."
  :group 'beads-ui)

(defface beads-status-progress-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for issues in progress."
  :group 'beads-ui)

(defface beads-status-blocked-face
  '((t :inherit error))
  "Face for blocked issues."
  :group 'beads-ui)

(defface beads-status-closed-face
  '((t :inherit shadow :strike-through t))
  "Face for closed issues."
  :group 'beads-ui)

(defface beads-issue-id-face
  '((t :inherit link :weight semi-bold))
  "Face for issue identifiers."
  :group 'beads-ui)

(defface beads-section-heading-face
  '((t :inherit font-lock-function-name-face :weight bold :height 1.1))
  "Face for headings in Beads buffers."
  :group 'beads-ui)

(defface beads-muted-face
  '((t :inherit shadow))
  "Face for secondary Beads information."
  :group 'beads-ui)

(declare-function beads-show "beads-show" (id &optional workspace))
(declare-function beads-create "beads-edit" (&optional workspace))
(declare-function beads-claim "beads-edit" (&optional id workspace))
(declare-function beads-close "beads-edit" (&optional id workspace))
(declare-function beads-reopen "beads-edit" (&optional id workspace))
(declare-function beads-update "beads-edit" (&optional id workspace))
(declare-function beads-menu "beads-transient" ())

(defvar beads-list-mode-map (make-sparse-keymap)
  "Keymap for `beads-list-mode'.")

;; Define bindings outside `defvar' so reloading this library updates an
;; existing list-mode map as well as a newly created one.
(set-keymap-parent beads-list-mode-map tabulated-list-mode-map)
(define-key beads-list-mode-map (kbd "RET") #'beads-list-show)
(define-key beads-list-mode-map (kbd "g") #'beads-list-refresh)
(define-key beads-list-mode-map (kbd "a") #'beads-list-all)
(define-key beads-list-mode-map (kbd "o") #'beads-list-open)
(define-key beads-list-mode-map (kbd "O") #'beads-list-open)
(define-key beads-list-mode-map (kbd "X") #'beads-list-closed)
(define-key beads-list-mode-map (kbd "r") #'beads-list-ready)
(define-key beads-list-mode-map (kbd "b") #'beads-list-blocked)
(define-key beads-list-mode-map (kbd "l") #'beads-list-label)
(define-key beads-list-mode-map (kbd "/") #'beads-list-search)
(define-key beads-list-mode-map (kbd "c") #'beads-create)
(define-key beads-list-mode-map (kbd "C") #'beads-claim)
(define-key beads-list-mode-map (kbd "e") #'beads-update)
(define-key beads-list-mode-map (kbd "x") #'beads-close)
(define-key beads-list-mode-map (kbd "R") #'beads-reopen)
(define-key beads-list-mode-map (kbd "?") #'beads-menu)

(easy-menu-define beads-list-mode-menu beads-list-mode-map
  "Menu for Beads issue lists."
  '("Beads"
    ["Show issue" beads-list-show :active (tabulated-list-get-id)]
    ["Refresh" beads-list-refresh t]
    "---"
    ["All issues" beads-list-all t]
    ["Open issues" beads-list-open t]
    ["Closed issues" beads-list-closed t]
    ["Ready issues" beads-list-ready t]
    ["Blocked issues" beads-list-blocked t]
    ["Filter by label..." beads-list-label t]
    ["Search..." beads-list-search t]
    "---"
    ["Create issue..." beads-create t]
    ["Claim issue" beads-claim :active (tabulated-list-get-id)]
    ["Edit issue..." beads-update :active (tabulated-list-get-id)]
    ["Close issue..." beads-close :active (tabulated-list-get-id)]
    ["Reopen issue..." beads-reopen :active (tabulated-list-get-id)]
    "---"
    ["Command menu" beads-menu t]))

(defvar-local beads-list-kind 'all
  "Kind of issue query displayed in the current buffer.")

(defvar-local beads-list-query nil
  "Search query displayed in the current buffer, or nil.")

(defvar-local beads-list-issues nil
  "Normalized issues displayed in the current buffer.")

(defvar-local beads-list--refresh-generation 0
  "Generation number of the newest list refresh.")

(defvar-local beads-list--selected-id nil
  "Issue to restore after the current refresh.")

(defvar-local beads-list--busy nil
  "Non-nil while the list is being refreshed.")

(defvar-local beads-list--displayed-width nil
  "Window width used for the most recent responsive row rendering.")

(defun beads-list--object-get (object key &optional default)
  "Return KEY from OBJECT, or DEFAULT.

This wrapper makes the renderer convenient to exercise independently."
  (let ((value (beads-object-get object key)))
    (if (null value) default value)))

(defun beads-list--string (value)
  "Convert VALUE to a display string."
  (cond
   ((null value) "")
   ((stringp value) value)
   ((symbolp value) (symbol-name value))
   (t (format "%s" value))))

(defun beads-list--priority-string (issue)
  "Return the formatted priority for ISSUE."
  (let* ((raw (beads-list--object-get issue 'priority ""))
         (text (beads-list--string raw))
         (priority (if (string-prefix-p "P" text) text (concat "P" text)))
         (face (pcase priority
                 ("P0" 'beads-priority-0-face)
                 ("P1" 'beads-priority-1-face)
                 ("P2" 'beads-priority-2-face)
                 (_ 'beads-priority-low-face))))
    (propertize priority 'face face)))

(defun beads-list--type-icon (issue)
  "Return a type icon with explanatory text for ISSUE."
  (let* ((type (beads-list--string (beads-list--object-get issue 'issue_type)))
         (icon (pcase type
                 ("bug" "🐛")
                 ("feature" "✨")
                 ("task" "📋")
                 ("epic" "🚀")
                 ("chore" "🧹")
                 (_ "•"))))
    (propertize icon 'help-echo
                (format "Type: %s" (if (string-empty-p type) "unknown" type)))))

(defun beads-list--status-string (issue)
  "Return the compact formatted status for ISSUE."
  (let* ((status (beads-list--string (beads-list--object-get issue 'status "")))
         (blocked-count
          (string-to-number
           (beads-list--string
            (beads-list--object-get issue 'blocked_by_count 0))))
         (blocked (or (string= status "blocked")
                      (equal beads-list-kind 'blocked)
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
                (blocked 'beads-status-blocked-face)
                ((string= status "closed") 'beads-status-closed-face)
                ((string= status "in_progress") 'beads-status-progress-face)
                ((string= status "open") 'beads-status-open-face)
                (t 'default))))
    (propertize label 'face face 'help-echo (format "Status: %s" status))))

(defun beads-list--relative-time (timestamp &optional now)
  "Return TIMESTAMP relative to NOW in the compact `bv' style."
  (let ((text (beads-list--string timestamp))
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

(defun beads-list--age-string (issue)
  "Return a muted relative creation age for ISSUE."
  (let* ((timestamp (or (beads-list--object-get issue 'created_at)
                        (beads-list--object-get issue 'updated_at)))
         (age (beads-list--relative-time timestamp)))
    (propertize age 'face 'beads-muted-face
                'help-echo (if timestamp
                               (format "Created: %s" timestamp)
                             "Creation time unknown"))))

(defun beads-list--entry (issue)
  "Convert ISSUE to a `tabulated-list-mode' entry."
  (let ((id (beads-list--string (beads-list--object-get issue 'id))))
    (list id
          (vector
           (beads-list--type-icon issue)
           (beads-list--priority-string issue)
           (beads-list--status-string issue)
           (propertize id 'face 'beads-issue-id-face)
           (beads-list--string (beads-list--object-get issue 'title))
           (beads-list--age-string issue)))))

(defun beads-list--entries ()
  "Return tabulated entries for `beads-list-issues'."
  (mapcar #'beads-list--entry beads-list-issues))

(defun beads-list--display-width ()
  "Return the usable display width for the current list buffer."
  (if-let* ((window (get-buffer-window (current-buffer) t)))
      (window-body-width window)
    80))

(defun beads-list--truncate (text width)
  "Truncate TEXT to display WIDTH with an ellipsis."
  (if (<= width 0)
      ""
    (truncate-string-to-width text width nil nil "…")))

(defun beads-list--print-entry (id columns)
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
         (width (max 24 (beads-list--display-width)))
         (fixed-prefix (concat "  " icon " " priority " " status " "))
         (minimum-title-width 8)
         (id-budget (max 0 (- width (string-width fixed-prefix)
                              age-width minimum-title-width 2)))
         (visible-id (beads-list--truncate issue-id id-budget))
         (prefix (concat fixed-prefix visible-id " "))
         (title-width (max 0 (- width (string-width prefix) age-width 1)))
         (visible-title (beads-list--truncate title title-width))
         (age-padding
          (max 1 (- width (string-width prefix) (string-width visible-title)
                   age-width))))
    (insert prefix visible-title)
    (insert (make-string age-padding ?\s))
    (insert (format (format "%%%ds" age-width) age) "\n")
    (add-text-properties
     beg (point)
     `(tabulated-list-id ,id tabulated-list-entry ,columns))))

(define-derived-mode beads-list-mode tabulated-list-mode "Beads"
  "Major mode for browsing Beads issues."
  (setq tabulated-list-format
        [("Type" 3 t)
         ("Priority" 3 beads-list--sort-priority)
         ("Status" 5 t)
         ("ID" 28 t)
         ("Title" 48 t)
         ("Age" 8 t :right-align t)])
  (setq tabulated-list-padding 0
        tabulated-list-entries #'beads-list--entries
        tabulated-list-printer #'beads-list--print-entry
        tabulated-list-sort-key '("Priority" . nil))
  (add-hook 'tabulated-list-revert-hook #'beads-list-refresh nil t)
  (add-hook 'window-size-change-functions
            #'beads-list--window-size-change nil t)
  (tabulated-list-init-header))

(defun beads-list--sort-priority (a b)
  "Return non-nil when entry A has a lower priority number than B."
  (< (string-to-number (string-remove-prefix "P" (aref (cadr a) 1)))
     (string-to-number (string-remove-prefix "P" (aref (cadr b) 1)))))

(defun beads-list--window-size-change (window)
  "Redisplay list rows after a width change in WINDOW."
  (let ((buffer (window-buffer window)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'beads-list-mode)
          (let ((width (window-body-width window)))
            (unless (equal width beads-list--displayed-width)
              (setq beads-list--displayed-width width
                    beads-list--selected-id (tabulated-list-get-id))
              (tabulated-list-print t)
              (beads-list--restore-selection beads-list--selected-id))))))))

(defun beads-list-current-id (&optional prompt)
  "Return the issue ID at point, prompting when needed if PROMPT is non-nil."
  (or (tabulated-list-get-id)
      (when prompt (read-string "Issue ID: "))))

(defun beads-list-show ()
  "Open the issue at point."
  (interactive)
  (let ((id (beads-list-current-id t)))
    (unless (string-empty-p id)
      (beads-show id beads-workspace))))

(defun beads-list--buffer-name (kind workspace &optional query)
  "Return a buffer name for KIND in WORKSPACE and optional QUERY."
  (format "*Beads %s: %s%s*"
          (capitalize (symbol-name kind))
          (file-name-nondirectory (directory-file-name workspace))
          (if query (format " — %s" query) "")))

(defun beads-list--view-title ()
  "Return a display title for the current list view."
  (pcase beads-list-kind
    ('all "All")
    ('open "Open")
    ('closed "Closed")
    ('ready "Ready")
    ('blocked "Blocked")
    ('label (format "Label: %s" beads-list-query))
    ('search (format "Search: %s" beads-list-query))
    (_ (capitalize (symbol-name beads-list-kind)))))

(defun beads-list--header-line ()
  "Return a responsive header for the current issue list."
  (list (format "%s — %s issue%s    TYPE PRI STATUS ID TITLE"
                (beads-list--view-title)
                (length beads-list-issues)
                (if (= (length beads-list-issues) 1) "" "s"))
        (propertize " " 'display '(space :align-to (- right-fringe 3)))
        "AGE"))

(defun beads-list--args ()
  "Return the `br' arguments for the current list view."
  (pcase beads-list-kind
    ('all '("list" "--all" "--json"))
    ('open '("list" "--status" "open" "--json"))
    ('closed '("list" "--status" "closed" "--json"))
    ('ready '("ready" "--json"))
    ('blocked '("blocked" "--json"))
    ('label (list "list" "--all" "--label"
                  (or beads-list-query "") "--json"))
    ('search (list "search" (or beads-list-query "") "--json"))
    (_ (error "Unknown Beads list kind: %S" beads-list-kind))))

(defun beads-list--set-busy (busy)
  "Set current list buffer BUSY state."
  (setq beads-list--busy busy)
  (setq mode-line-process (and busy '(" " (:propertize "loading" face warning))))
  (force-mode-line-update))

(defun beads-list--restore-selection (id)
  "Move point to issue ID if it is present."
  (goto-char (point-min))
  (when id
    (unless (catch 'found
              (while (not (eobp))
                (when (equal (tabulated-list-get-id) id)
                  (throw 'found t))
                (forward-line 1)))
      (goto-char (point-min)))))

(defun beads-list--success (buffer generation json)
  "Install JSON in BUFFER if GENERATION is current."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation beads-list--refresh-generation)
        (setq beads-list-issues (beads-json-issues json))
        (beads-list--set-busy nil)
        (setq beads-list--displayed-width (beads-list--display-width))
        (tabulated-list-print t)
        (beads-list--restore-selection beads-list--selected-id)
        (setq header-line-format (beads-list--header-line))))))

(defun beads-list--failure (buffer generation error-data)
  "Report ERROR-DATA for BUFFER if GENERATION is current."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (= generation beads-list--refresh-generation)
        (beads-list--set-busy nil)
        (message "Beads refresh failed: %s" error-data)))))

(defun beads-list-refresh ()
  "Refresh the current issue list asynchronously."
  (interactive)
  (unless (derived-mode-p 'beads-list-mode)
    (user-error "This is not a Beads issue-list buffer"))
  (setq beads-list--selected-id (tabulated-list-get-id))
  (cl-incf beads-list--refresh-generation)
  (let ((buffer (current-buffer))
        (generation beads-list--refresh-generation))
    (beads-list--set-busy t)
    (beads-br-async (beads-list--args)
                    (lambda (json)
                      (beads-list--success buffer generation json))
                    (lambda (error-data)
                      (beads-list--failure buffer generation error-data))
                    beads-workspace buffer)))

(defun beads-list--open (kind &optional directory query)
  "Open a KIND list in DIRECTORY, optionally for search QUERY."
  (let* ((workspace (beads-workspace-root directory))
         (buffer (get-buffer-create
                  (beads-list--buffer-name kind workspace query))))
    (with-current-buffer buffer
      (beads-list-mode)
      (setq-local beads-workspace workspace)
      (setq-local beads-list-kind kind)
      (setq-local beads-list-query query)
      (setq-local revert-buffer-function
                  (lambda (&rest _ignored) (beads-list-refresh)))
      (beads-watch-workspace #'beads-list-refresh)
      (beads-list-refresh))
    (pop-to-buffer buffer)
    buffer))

(defun beads-list--switch (kind &optional query)
  "Switch the current list buffer to KIND and optional QUERY."
  (unless (derived-mode-p 'beads-list-mode)
    (user-error "This is not a Beads issue-list buffer"))
  (setq beads-list-kind kind
        beads-list-query query)
  (rename-buffer (beads-list--buffer-name kind beads-workspace query) t)
  (beads-list-refresh)
  (current-buffer))

(defun beads-list--visit (kind &optional directory query)
  "Switch to or open a KIND list in DIRECTORY with optional QUERY."
  (if (and (derived-mode-p 'beads-list-mode)
           (or (null directory)
               (equal beads-workspace
                      (let ((beads-workspace nil))
                        (beads-workspace-root directory)))))
      (beads-list--switch kind query)
    (beads-list--open kind directory query)))

(defun beads-list--known-labels (workspace)
  "Return sorted issue labels found in WORKSPACE."
  (let (result)
    (dolist (issue (beads-json-issues
                    (beads-br-sync '("list" "--all" "--json") workspace)))
      (let ((labels (beads-object-get issue 'labels)))
        (dolist (label (cond
                        ((vectorp labels) (append labels nil))
                        ((listp labels) labels)))
          (when (and (stringp label) (not (string-empty-p label)))
            (cl-pushnew label result :test #'equal)))))
    (sort result #'string-lessp)))

(defun beads-list--read-label (workspace)
  "Read an existing issue label from WORKSPACE."
  (let ((labels (beads-list--known-labels workspace)))
    (unless labels
      (user-error "No Beads labels found in %s" workspace))
    (completing-read "Label: " labels nil t)))

;;;###autoload
(defun beads-list (&optional directory)
  "Open all Beads issues in DIRECTORY."
  (interactive)
  (beads-list--visit 'all directory))

;;;###autoload
(defun beads-list-all (&optional directory)
  "Show all Beads issues in DIRECTORY."
  (interactive)
  (beads-list--visit 'all directory))

;;;###autoload
(defun beads-list-open (&optional directory)
  "Show open Beads issues in DIRECTORY."
  (interactive)
  (beads-list--visit 'open directory))

;;;###autoload
(defun beads-list-closed (&optional directory)
  "Show closed Beads issues in DIRECTORY."
  (interactive)
  (beads-list--visit 'closed directory))

;;;###autoload
(defun beads-list-ready (&optional directory)
  "Show ready Beads issues in DIRECTORY."
  (interactive)
  (beads-list--visit 'ready directory))

;;;###autoload
(defalias 'beads-ready #'beads-list-ready)

;;;###autoload
(defun beads-list-blocked (&optional directory)
  "Show blocked Beads issues in DIRECTORY."
  (interactive)
  (beads-list--visit 'blocked directory))

;;;###autoload
(defalias 'beads-blocked #'beads-list-blocked)

;;;###autoload
(defun beads-list-label (label &optional directory)
  "Show issues with LABEL in the Beads workspace at DIRECTORY."
  (interactive
   (let ((workspace (beads-workspace-root)))
     (list (beads-list--read-label workspace) nil)))
  (when (string-empty-p label)
    (user-error "Label cannot be empty"))
  (beads-list--visit 'label directory label))

;;;###autoload
(defun beads-list-search (query &optional directory)
  "Search for QUERY in the Beads workspace at DIRECTORY."
  (interactive (list (read-string "Search Beads: ") beads-workspace))
  (when (string-empty-p query)
    (user-error "Search text cannot be empty"))
  (beads-list--visit 'search directory query))

;;;###autoload
(defalias 'beads-search #'beads-list-search)

(provide 'beads-list)
;;; beads-list.el ends here
