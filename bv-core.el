;;; bv-core.el --- Process and workspace support for Beads  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: Dave Beckett <dave@dajobe.org>
;; Keywords: tools
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; This library is the structured boundary between Emacs and the `br' and
;; `bv' programs.  It deliberately accepts argument lists, never shell command
;; strings, and normalizes decoded JSON objects to alists with string keys.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'filenotify)
(require 'map)
(require 'seq)
(require 'subr-x)

(defgroup bv nil
  "Emacs interface to the Beads tools."
  :group 'tools)

(defcustom bv-br-executable "br"
  "Name or absolute path of the br executable."
  :type 'file)

(defcustom bv-bv-executable "bv"
  "Name or absolute path of the bv executable."
  :type 'file)

(defcustom bv-default-workspace nil
  "Default Beads workspace directory.
When nil, discover a workspace from `default-directory'."
  :type '(choice (const :tag "Discover from current directory" nil)
                 directory))

(defcustom bv-database-file nil
  "Explicit Beads database passed to commands with --db.
The path may be absolute or relative to the selected workspace."
  :type '(choice (const :tag "Use workspace default" nil) file))

(defcustom bv-error-buffer-name "*bv errors*"
  "Name of the buffer containing subprocess diagnostics."
  :type 'string)

(defcustom bv-auto-refresh-on-change t
  "Whether visible Beads buffers refresh after external JSONL changes."
  :type 'boolean)

(defcustom bv-auto-refresh-delay 0.25
  "Seconds to debounce automatic refreshes after Beads JSONL changes."
  :type 'number)

(defvar-local bv-workspace nil
  "Workspace explicitly associated with the current buffer.")

(defvar-local bv--active-process nil)
(defvar-local bv--request-generation 0)
(defvar-local bv--file-watch nil)
(defvar-local bv--rewatch-needed nil)
(defvar-local bv--auto-refresh-timer nil)

(defvar bv-before-refresh-hook nil
  "Hook run in the target buffer before an asynchronous command starts.")

(defvar bv-after-refresh-hook nil
  "Hook run in the target buffer after an asynchronous command succeeds.")

(defvar bv-refresh-error-hook nil
  "Hook run in the target buffer after an asynchronous command fails.")

(define-error 'bv-command-error "Beads command failed")
(define-error 'bv-json-error "Invalid JSON from a Beads command"
  'bv-command-error)

(defun bv--marker-directory (directory)
  "Return the workspace containing DIRECTORY, or nil."
  (let ((directory (file-name-as-directory (expand-file-name directory))))
    (locate-dominating-file
     directory
     (lambda (candidate)
       (or (file-directory-p (expand-file-name ".beads" candidate))
           (file-directory-p (expand-file-name "_beads" candidate)))))))

(defun bv-workspace-root (&optional directory)
  "Return the normalized Beads workspace root for DIRECTORY.
Selection prefers buffer-local `bv-workspace', then DIRECTORY,
`bv-default-workspace', and finally discovery above `default-directory'.
Signal `user-error' when no workspace can be found."
  (let* ((selected (or bv-workspace directory bv-default-workspace
                       default-directory))
         (root (bv--marker-directory selected)))
    (unless root
      (user-error "No Beads workspace found from %s" selected))
    (file-name-as-directory (file-truename root))))

(defun bv--beads-directory (workspace)
  "Return the Beads data directory inside WORKSPACE, or nil."
  (seq-find #'file-directory-p
            (mapcar (lambda (name) (expand-file-name name workspace))
                    '(".beads" "_beads"))))

(defun bv--issues-watch-target (workspace)
  "Return the best file notification target for WORKSPACE."
  (when-let* ((directory (bv--beads-directory workspace)))
    (or (seq-find #'file-exists-p
                  (mapcar (lambda (name) (expand-file-name name directory))
                          '("issues.jsonl" "beads.jsonl")))
        directory)))

(defun bv--jsonl-change-event-p (event)
  "Return non-nil when file notification EVENT concerns issue JSONL."
  (and (not (eq (cadr event) 'stopped))
       (seq-some
        (lambda (path)
          (and (stringp path)
               (member (file-name-nondirectory path)
                       '("issues.jsonl" "beads.jsonl"))))
        (cddr event))))

(defun bv--auto-refresh-now (buffer refresh-function)
  "Refresh BUFFER with REFRESH-FUNCTION when it is visible and idle."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq bv--auto-refresh-timer nil)
      (when (and bv-auto-refresh-on-change bv--rewatch-needed)
        (setq bv--rewatch-needed nil)
        (let ((descriptor bv--file-watch))
          (setq bv--file-watch nil)
          (when descriptor
            (ignore-errors (file-notify-rm-watch descriptor))))
        (bv--add-workspace-watch buffer refresh-function))
      (when (and bv-auto-refresh-on-change
                 (get-buffer-window buffer t))
        (if (process-live-p bv--active-process)
            (bv--schedule-auto-refresh buffer refresh-function)
          (funcall refresh-function))))))

(defun bv--schedule-auto-refresh (buffer refresh-function)
  "Schedule a debounced REFRESH-FUNCTION call for BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp bv--auto-refresh-timer)
        (cancel-timer bv--auto-refresh-timer))
      (setq bv--auto-refresh-timer
            (run-at-time bv-auto-refresh-delay nil
                         #'bv--auto-refresh-now buffer refresh-function)))))

(defun bv--file-watch-callback (buffer refresh-function event)
  "Handle Beads file notification EVENT for BUFFER.
REFRESH-FUNCTION refreshes the owning UI buffer."
  (when (buffer-live-p buffer)
    (when (bv--jsonl-change-event-p event)
      (bv--schedule-auto-refresh buffer refresh-function))
    (when (and (memq (cadr event) '(created deleted renamed))
               (with-current-buffer buffer
                 (equal (car event) bv--file-watch)))
      (with-current-buffer buffer
        (setq bv--rewatch-needed t)
        (unless (eq (cadr event) 'created)
          (setq bv--file-watch nil))))))

(defun bv--add-workspace-watch (buffer refresh-function)
  "Add BUFFER's file watch and arrange to call REFRESH-FUNCTION later."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((target (and bv-workspace
                              (bv--issues-watch-target bv-workspace))))
        (condition-case nil
            (setq bv--file-watch
                  (file-notify-add-watch
                   target '(change attribute-change)
                   (lambda (event)
                     (bv--file-watch-callback
                      buffer refresh-function event))))
          ((file-notify-error file-error)
           (setq bv--file-watch nil)))))))

(defun bv-unwatch-workspace ()
  "Remove file notification and refresh timer owned by this buffer."
  (when (timerp bv--auto-refresh-timer)
    (cancel-timer bv--auto-refresh-timer))
  (setq bv--auto-refresh-timer nil)
  (setq bv--rewatch-needed nil)
  (let ((descriptor bv--file-watch))
    (setq bv--file-watch nil)
    (when descriptor
      (ignore-errors (file-notify-rm-watch descriptor)))))

(defun bv-watch-workspace (refresh-function)
  "Watch the current workspace and call REFRESH-FUNCTION after JSONL writes.

File notification failures are non-fatal because manual refresh remains
available.  Return the watch descriptor, or nil when watching is unavailable."
  (bv-unwatch-workspace)
  (when bv-auto-refresh-on-change
    (bv--add-workspace-watch (current-buffer) refresh-function))
  (when bv--file-watch
    (add-hook 'kill-buffer-hook #'bv-unwatch-workspace nil t))
  bv--file-watch)

(defun bv--normalize-json (value)
  "Normalize JSON VALUE recursively to lists and string-keyed alists."
  (cond
   ((hash-table-p value)
    (map-apply (lambda (key item)
                 (cons (if (symbolp key) (symbol-name key) key)
                       (bv--normalize-json item)))
               value))
   ((vectorp value)
    (mapcar #'bv--normalize-json (append value nil)))
   ((and (listp value)
         (or (null value)
             (and (consp (car value))
                  (or (stringp (caar value)) (symbolp (caar value))))))
    (mapcar (lambda (entry)
              (if (consp entry)
                  (cons (if (symbolp (car entry))
                            (symbol-name (car entry))
                          (car entry))
                        (bv--normalize-json (cdr entry)))
                (bv--normalize-json entry)))
            value))
   ((listp value) (mapcar #'bv--normalize-json value))
   (t value)))

(defun bv-json-decode (text)
  "Decode TEXT and return normalized JSON data.
Objects use string keys, arrays use lists, JSON null becomes nil, and JSON
false remains distinguishable as `:json-false'."
  (condition-case error-data
      (bv--normalize-json
       (json-parse-string text
                          :object-type 'alist
                          :array-type 'list
                          :null-object nil
                          :false-object :json-false))
    (json-parse-error
     (signal 'bv-json-error
             (list (list :message (error-message-string error-data)
                         :output text))))))

(defun bv-object-get (object key &optional default)
  "Return KEY from JSON OBJECT, or DEFAULT when it is absent.
KEY may be a symbol or string and OBJECT may have either kind of key."
  (let* ((string-key (if (symbolp key) (symbol-name key) key))
         (symbol-key (and (stringp string-key) (intern-soft string-key)))
         (missing (make-symbol "missing"))
         (value
          (cond
           ((hash-table-p object)
            (let ((found (gethash string-key object missing)))
              (if (and (eq found missing) symbol-key)
                  (gethash symbol-key object missing)
                found)))
           ((listp object)
            (let ((entry (or (assoc string-key object)
                             (and symbol-key (assq symbol-key object)))))
              (if entry (cdr entry) missing)))
           (t missing))))
    (if (eq value missing) default value)))

(defun bv-object-member-p (object key)
  "Return non-nil when JSON OBJECT contain KEY, even when its value is nil."
  (let ((missing (make-symbol "missing")))
    (not (eq (bv-object-get object key missing) missing))))

(defun bv-json-issues (data)
  "Return the issue list represented by decoded DATA.
Handle a list response, a single issue object, and the `issues' envelope used
by some br versions."
  (cond
   ((bv-object-member-p data "issues") (bv-object-get data "issues"))
   ((bv-object-member-p data "id") (list data))
   ((or (null data)
        (and (listp data) (consp (car data))
             (not (stringp (caar data)))))
    data)
   (t (signal 'bv-json-error
              (list (list :message "Expected issue JSON" :output data))))))

(defun bv--database-arguments (workspace)
  "Return database arguments appropriate for WORKSPACE."
  (when bv-database-file
    (list "--db" (expand-file-name bv-database-file workspace))))

(defun bv--record-error (data)
  "Append subprocess error DATA to `bv-error-buffer-name'."
  (with-current-buffer (get-buffer-create bv-error-buffer-name)
    (goto-char (point-max))
    (insert (format-time-string "\n[%Y-%m-%d %H:%M:%S] "))
    (insert (format "%s %S\nexit: %S\nstderr:\n%s\nstdout:\n%s\n"
                    (plist-get data :program)
                    (plist-get data :arguments)
                    (plist-get data :status)
                    (or (plist-get data :stderr) "")
                    (or (plist-get data :stdout) "")))))

(defun bv-command-sync (program arguments &optional workspace)
  "Run PROGRAM synchronously with ARGUMENTS and decode its JSON output.
WORKSPACE defaults to `bv-workspace-root'.  Signal `bv-command-error' with a
diagnostic plist on failure."
  (declare (indent 1))
  (unless (and (stringp program) (listp arguments)
               (seq-every-p #'stringp arguments))
    (error "PROGRAM must be a string and ARGUMENTS a list of strings"))
  (let* ((root (bv-workspace-root workspace))
         (default-directory root)
         (arguments (append (bv--database-arguments root) arguments))
         (stdout (generate-new-buffer " *bv stdout*"))
         (stderr-file (make-temp-file "bv-stderr-"))
         status stderr output)
    (unwind-protect
        (progn
          (condition-case process-error
              (setq status (apply #'process-file program nil
                                  (list stdout stderr-file) nil arguments)
                    stderr (with-temp-buffer
                             (insert-file-contents stderr-file)
                             (buffer-string))
                    output (with-current-buffer stdout (buffer-string)))
            (file-error
             (setq status 'file-error
                   stderr (error-message-string process-error)
                   output "")))
          (if (and (integerp status) (zerop status))
              (condition-case json-error
                  (bv-json-decode output)
                (bv-json-error
                 (let ((data (list :program program :arguments arguments
                                   :workspace root :status status
                                   :stdout output :stderr stderr
                                   :json-error (cadr json-error))))
                   (bv--record-error data)
                   (signal 'bv-json-error (list data)))))
            (let ((data (list :program program :arguments arguments
                              :workspace root :status status
                              :stdout output :stderr stderr)))
              (bv--record-error data)
              (signal 'bv-command-error (list data)))))
      (kill-buffer stdout)
      (delete-file stderr-file))))

(defun bv-br-sync (arguments &optional workspace)
  "Run br synchronously with ARGUMENTS in WORKSPACE and decode JSON."
  (bv-command-sync bv-br-executable arguments workspace))

(defun bv-bv-sync (arguments &optional workspace)
  "Run bv synchronously with ARGUMENTS in WORKSPACE and decode JSON."
  (bv-command-sync bv-bv-executable arguments workspace))

(defun bv-cancel-request (&optional buffer)
  "Cancel the active asynchronous request owned by BUFFER.
BUFFER defaults to the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (when (process-live-p bv--active-process)
      (delete-process bv--active-process))
    (setq bv--active-process nil)))

(defun bv--kill-owned-process ()
  "Cancel the process owned by the current buffer."
  (bv-cancel-request (current-buffer)))

(defun bv--async-finished (process target generation program arguments root
                                   stdout stderr callback error-callback)
  "Handle completion of an asynchronous Beads PROCESS.
TARGET is the owning buffer and GENERATION identifies the request.  PROGRAM,
ARGUMENTS, and ROOT describe the invocation; STDOUT and STDERR are its output
buffers.  CALLBACK handles success and ERROR-CALLBACK handles failure."
  (when (memq (process-status process) '(exit signal))
    (let ((status (process-exit-status process))
          (output (when (buffer-live-p stdout)
                    (with-current-buffer stdout (buffer-string))))
          (error-output (when (buffer-live-p stderr)
                          (with-current-buffer stderr (buffer-string)))))
      (unwind-protect
          (when (and (buffer-live-p target)
                     (with-current-buffer target
                       (= generation bv--request-generation)))
            (with-current-buffer target
              (setq bv--active-process nil)
              (let ((failure
                     (list :program program :arguments arguments
                           :workspace root :status status
                           :stdout output :stderr error-output)))
                (if (zerop status)
                    (condition-case json-error
                        (progn
                          (funcall callback (bv-json-decode output))
                          (run-hooks 'bv-after-refresh-hook))
                      (bv-command-error
                       (setq failure
                             (append failure
                                     (list :json-error (cadr json-error))))
                       (bv--record-error failure)
                       (when error-callback (funcall error-callback failure))
                       (run-hooks 'bv-refresh-error-hook)))
                  (bv--record-error failure)
                  (when error-callback (funcall error-callback failure))
                  (run-hooks 'bv-refresh-error-hook)))))
        (when (buffer-live-p stdout) (kill-buffer stdout))
        (when (buffer-live-p stderr) (kill-buffer stderr))))))

(defun bv-command-async (program arguments callback
                                 &optional error-callback workspace buffer)
  "Run PROGRAM asynchronously with ARGUMENTS and decode its JSON output.
CALLBACK receives decoded data in BUFFER, which defaults to the current
buffer.  ERROR-CALLBACK receives the `bv-command-error' diagnostic plist.
WORKSPACE selects the command directory explicitly.
A newer request in the same buffer supersedes this one.  Return the process."
  (unless (and (stringp program) (listp arguments)
               (seq-every-p #'stringp arguments))
    (error "PROGRAM must be a string and ARGUMENTS a list of strings"))
  (let* ((target (or buffer (current-buffer)))
         (root (with-current-buffer target (bv-workspace-root workspace)))
         (argv (append (bv--database-arguments root) arguments))
         (stdout (generate-new-buffer " *bv async stdout*"))
         (stderr (generate-new-buffer " *bv async stderr*"))
         generation process)
    (with-current-buffer target
      (setq generation (cl-incf bv--request-generation))
      (bv-cancel-request target)
      (add-hook 'kill-buffer-hook #'bv--kill-owned-process nil t)
      (run-hooks 'bv-before-refresh-hook))
    (let ((default-directory root))
      (condition-case process-error
          (setq process
                (make-process
                 :name (format "bv-%d" generation)
                 :buffer stdout :stderr stderr :noquery t
                 :command (cons program argv)
                 :sentinel
                 (lambda (proc _event)
                   (bv--async-finished
                    proc target generation program argv root stdout stderr
                    callback error-callback))))
        (file-error
         (let ((data (list :program program :arguments argv :workspace root
                           :status 'file-error
                           :stderr (error-message-string process-error))))
           (kill-buffer stdout)
           (kill-buffer stderr)
           (with-current-buffer target
             (when (= generation bv--request-generation)
               (setq bv--active-process nil)
               (bv--record-error data)
               (when error-callback (funcall error-callback data))
               (run-hooks 'bv-refresh-error-hook)))
           (signal 'bv-command-error (list data))))))
    (with-current-buffer target (setq bv--active-process process))
    process))

(defun bv-br-async (arguments callback &optional error-callback workspace buffer)
  "Run br asynchronously with ARGUMENTS, invoking CALLBACK with JSON data.
ERROR-CALLBACK, WORKSPACE, and BUFFER are as in `bv-command-async'."
  (bv-command-async bv-br-executable arguments callback
                    error-callback workspace buffer))

(defun bv-bv-async (arguments callback &optional error-callback workspace buffer)
  "Run bv asynchronously with ARGUMENTS, invoking CALLBACK with JSON data.
ERROR-CALLBACK, WORKSPACE, and BUFFER are as in `bv-command-async'."
  (bv-command-async bv-bv-executable arguments callback
                    error-callback workspace buffer))

(provide 'bv-core)

;;; bv-core.el ends here
