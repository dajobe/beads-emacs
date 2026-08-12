;;; beads-core.el --- Process and workspace support for Beads  -*- lexical-binding: t; -*-

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

(defgroup beads nil
  "Emacs interface to the Beads tools."
  :group 'tools)

(defcustom beads-br-executable "br"
  "Name of the br executable to find on the variable `exec-path'."
  :type 'string)

(defcustom beads-bv-executable "bv"
  "Name of the bv executable to find on the variable `exec-path'."
  :type 'string)

(defcustom beads-default-workspace nil
  "Default Beads workspace directory.
When nil, discover a workspace from `default-directory'."
  :type '(choice (const :tag "Discover from current directory" nil)
                 directory))

(defcustom beads-database-file nil
  "Explicit Beads database passed to commands with --db.
The path may be absolute or relative to the selected workspace."
  :type '(choice (const :tag "Use workspace default" nil) file))

(defcustom beads-error-buffer-name "*Beads errors*"
  "Name of the buffer containing subprocess diagnostics."
  :type 'string)

(defcustom beads-auto-refresh-on-change t
  "Whether visible Beads buffers refresh after external JSONL changes."
  :type 'boolean)

(defcustom beads-auto-refresh-delay 0.25
  "Seconds to debounce automatic refreshes after Beads JSONL changes."
  :type 'number)

(defvar-local beads-workspace nil
  "Workspace explicitly associated with the current buffer.")

(defvar-local beads--active-process nil)
(defvar-local beads--request-generation 0)
(defvar-local beads--file-watch nil)
(defvar-local beads--rewatch-needed nil)
(defvar-local beads--auto-refresh-timer nil)

(defvar beads-before-refresh-hook nil
  "Hook run in the target buffer before an asynchronous command starts.")

(defvar beads-after-refresh-hook nil
  "Hook run in the target buffer after an asynchronous command succeeds.")

(defvar beads-refresh-error-hook nil
  "Hook run in the target buffer after an asynchronous command fails.")

(define-error 'beads-command-error "Beads command failed")
(define-error 'beads-json-error "Invalid JSON from a Beads command"
              'beads-command-error)

(defun beads--resolve-executable (program)
  "Return the executable path for PROGRAM found through variable `exec-path'.
PROGRAM must be a command name without a directory component."
  (unless (and (stringp program)
               (not (string-empty-p program))
               (equal program (file-name-nondirectory program)))
    (signal 'file-missing
            (list "Executable must be a command name on exec-path" program)))
  (or (executable-find program)
      (signal 'file-missing
              (list "Executable not found on exec-path" program))))

(defun beads--marker-directory (directory)
  "Return the workspace containing DIRECTORY, or nil."
  (let ((directory (file-name-as-directory (expand-file-name directory))))
    (locate-dominating-file
     directory
     (lambda (candidate)
       (or (file-directory-p (expand-file-name ".beads" candidate))
           (file-directory-p (expand-file-name "_beads" candidate)))))))

(defun beads-workspace-root (&optional directory)
  "Return the normalized Beads workspace root for DIRECTORY.
Selection prefers buffer-local `beads-workspace', then DIRECTORY,
`beads-default-workspace', and finally discovery above `default-directory'.
Signal `user-error' when no workspace can be found."
  (let* ((selected (or beads-workspace directory beads-default-workspace
                       default-directory))
         (root (beads--marker-directory selected)))
    (unless root
      (user-error "No Beads workspace found from %s" selected))
    (file-name-as-directory (file-truename root))))

(defun beads--beads-directory (workspace)
  "Return the Beads data directory inside WORKSPACE, or nil."
  (seq-find #'file-directory-p
            (mapcar (lambda (name) (expand-file-name name workspace))
                    '(".beads" "_beads"))))

(defun beads--issues-watch-target (workspace)
  "Return the best file notification target for WORKSPACE."
  (when-let* ((directory (beads--beads-directory workspace)))
    (or (seq-find #'file-exists-p
                  (mapcar (lambda (name) (expand-file-name name directory))
                          '("issues.jsonl" "beads.jsonl")))
        directory)))

(defun beads--jsonl-change-event-p (event)
  "Return non-nil when file notification EVENT concerns issue JSONL."
  (and (not (eq (cadr event) 'stopped))
       (seq-some
        (lambda (path)
          (and (stringp path)
               (member (file-name-nondirectory path)
                       '("issues.jsonl" "beads.jsonl"))))
        (cddr event))))

(defun beads--auto-refresh-now (buffer refresh-function)
  "Refresh BUFFER with REFRESH-FUNCTION when it is visible and idle."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq beads--auto-refresh-timer nil)
      (when (and beads-auto-refresh-on-change beads--rewatch-needed)
        (setq beads--rewatch-needed nil)
        (let ((descriptor beads--file-watch))
          (setq beads--file-watch nil)
          (when descriptor
            (ignore-errors (file-notify-rm-watch descriptor))))
        (beads--add-workspace-watch buffer refresh-function))
      (when (and beads-auto-refresh-on-change
                 (get-buffer-window buffer t))
        (if (process-live-p beads--active-process)
            (beads--schedule-auto-refresh buffer refresh-function)
          (funcall refresh-function))))))

(defun beads--schedule-auto-refresh (buffer refresh-function)
  "Schedule a debounced REFRESH-FUNCTION call for BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp beads--auto-refresh-timer)
        (cancel-timer beads--auto-refresh-timer))
      (setq beads--auto-refresh-timer
            (run-at-time beads-auto-refresh-delay nil
                         #'beads--auto-refresh-now buffer refresh-function)))))

(defun beads--file-watch-callback (buffer refresh-function event)
  "Handle Beads file notification EVENT for BUFFER.
REFRESH-FUNCTION refreshes the owning UI buffer."
  (when (buffer-live-p buffer)
    (when (beads--jsonl-change-event-p event)
      (beads--schedule-auto-refresh buffer refresh-function))
    (when (and (memq (cadr event) '(created deleted renamed))
               (with-current-buffer buffer
                 (equal (car event) beads--file-watch)))
      (with-current-buffer buffer
        (setq beads--rewatch-needed t)
        (unless (eq (cadr event) 'created)
          (setq beads--file-watch nil))))))

(defun beads--add-workspace-watch (buffer refresh-function)
  "Add BUFFER's file watch and arrange to call REFRESH-FUNCTION later."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((target (and beads-workspace
                               (beads--issues-watch-target beads-workspace))))
        (condition-case nil
            (setq beads--file-watch
                  (file-notify-add-watch
                   target '(change attribute-change)
                   (lambda (event)
                     (beads--file-watch-callback
                      buffer refresh-function event))))
          ((file-notify-error file-error)
           (setq beads--file-watch nil)))))))

(defun beads-unwatch-workspace ()
  "Remove file notification and refresh timer owned by this buffer."
  (when (timerp beads--auto-refresh-timer)
    (cancel-timer beads--auto-refresh-timer))
  (setq beads--auto-refresh-timer nil)
  (setq beads--rewatch-needed nil)
  (let ((descriptor beads--file-watch))
    (setq beads--file-watch nil)
    (when descriptor
      (ignore-errors (file-notify-rm-watch descriptor)))))

(defun beads-watch-workspace (refresh-function)
  "Watch the current workspace and call REFRESH-FUNCTION after JSONL writes.

File notification failures are non-fatal because manual refresh remains
available.  Return the watch descriptor, or nil when watching is unavailable."
  (beads-unwatch-workspace)
  (when beads-auto-refresh-on-change
    (beads--add-workspace-watch (current-buffer) refresh-function))
  (when beads--file-watch
    (add-hook 'kill-buffer-hook #'beads-unwatch-workspace nil t))
  beads--file-watch)

(defun beads--normalize-json (value)
  "Normalize JSON VALUE recursively to lists and string-keyed alists."
  (cond
   ((hash-table-p value)
    (map-apply (lambda (key item)
                 (cons (if (symbolp key) (symbol-name key) key)
                       (beads--normalize-json item)))
               value))
   ((vectorp value)
    (mapcar #'beads--normalize-json (append value nil)))
   ((and (listp value)
         (or (null value)
             (and (consp (car value))
                  (or (stringp (caar value)) (symbolp (caar value))))))
    (mapcar (lambda (entry)
              (if (consp entry)
                  (cons (if (symbolp (car entry))
                            (symbol-name (car entry))
                          (car entry))
                        (beads--normalize-json (cdr entry)))
                (beads--normalize-json entry)))
            value))
   ((listp value) (mapcar #'beads--normalize-json value))
   (t value)))

(defun beads-json-decode (text)
  "Decode TEXT and return normalized JSON data.
Objects use string keys, arrays use lists, JSON null becomes nil, and JSON
false remains distinguishable as `:json-false'."
  (condition-case error-data
      (beads--normalize-json
       (json-parse-string text
                          :object-type 'alist
                          :array-type 'list
                          :null-object nil
                          :false-object :json-false))
    (json-parse-error
     (signal 'beads-json-error
             (list (list :message (error-message-string error-data)
                         :output text))))))

(defun beads-object-get (object key &optional default)
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

(defun beads-object-member-p (object key)
  "Return non-nil when JSON OBJECT contain KEY, even when its value is nil."
  (let ((missing (make-symbol "missing")))
    (not (eq (beads-object-get object key missing) missing))))

(defun beads-json-issues (data)
  "Return the issue list represented by decoded DATA.
Handle a list response, a single issue object, and the `issues' envelope used
by some br versions."
  (cond
   ((beads-object-member-p data "issues") (beads-object-get data "issues"))
   ((beads-object-member-p data "id") (list data))
   ((or (null data)
        (and (listp data) (consp (car data))
             (not (stringp (caar data)))))
    data)
   (t (signal 'beads-json-error
              (list (list :message "Expected issue JSON" :output data))))))

(defun beads--database-arguments (workspace)
  "Return database arguments appropriate for WORKSPACE."
  (when beads-database-file
    (list "--db" (expand-file-name beads-database-file workspace))))

(defun beads--record-error (data)
  "Append subprocess error DATA to `beads-error-buffer-name'."
  (with-current-buffer (get-buffer-create beads-error-buffer-name)
    (goto-char (point-max))
    (insert (format-time-string "\n[%Y-%m-%d %H:%M:%S] "))
    (insert (format "%s %S\nexit: %S\nstderr:\n%s\nstdout:\n%s\n"
                    (plist-get data :program)
                    (plist-get data :arguments)
                    (plist-get data :status)
                    (or (plist-get data :stderr) "")
                    (or (plist-get data :stdout) "")))))

(defun beads-command-sync (program arguments &optional workspace)
  "Run PROGRAM synchronously with ARGUMENTS and decode its JSON output.
WORKSPACE defaults to `beads-workspace-root'.  Signal
`beads-command-error' with a diagnostic plist on failure."
  (declare (indent 1))
  (unless (and (stringp program) (listp arguments)
               (seq-every-p #'stringp arguments))
    (error "PROGRAM must be a string and ARGUMENTS a list of strings"))
  (let* ((root (beads-workspace-root workspace))
         (default-directory root)
         (arguments (append (beads--database-arguments root) arguments))
         (stdout (generate-new-buffer " *Beads stdout*"))
         (stderr-file (make-temp-file "beads-stderr-"))
         status stderr output)
    (unwind-protect
        (progn
          (condition-case process-error
              (setq status (apply #'process-file
                                  (beads--resolve-executable program) nil
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
                  (beads-json-decode output)
                (beads-json-error
                 (let ((data (list :program program :arguments arguments
                                   :workspace root :status status
                                   :stdout output :stderr stderr
                                   :json-error (cadr json-error))))
                   (beads--record-error data)
                   (signal 'beads-json-error (list data)))))
            (let ((data (list :program program :arguments arguments
                              :workspace root :status status
                              :stdout output :stderr stderr)))
              (beads--record-error data)
              (signal 'beads-command-error (list data)))))
      (kill-buffer stdout)
      (delete-file stderr-file))))

(defun beads-br-sync (arguments &optional workspace)
  "Run br synchronously with ARGUMENTS in WORKSPACE and decode JSON."
  (beads-command-sync beads-br-executable arguments workspace))

(defun beads-bv-sync (arguments &optional workspace)
  "Run bv synchronously with ARGUMENTS in WORKSPACE and decode JSON."
  (beads-command-sync beads-bv-executable arguments workspace))

(defun beads-cancel-request (&optional buffer)
  "Cancel the active asynchronous request owned by BUFFER.
BUFFER defaults to the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (when (process-live-p beads--active-process)
      (delete-process beads--active-process))
    (setq beads--active-process nil)))

(defun beads--kill-owned-process ()
  "Cancel the process owned by the current buffer."
  (beads-cancel-request (current-buffer)))

(defun beads--async-finished (process target generation program arguments root
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
                       (= generation beads--request-generation)))
            (with-current-buffer target
              (setq beads--active-process nil)
              (let ((failure
                     (list :program program :arguments arguments
                           :workspace root :status status
                           :stdout output :stderr error-output)))
                (if (zerop status)
                    (condition-case json-error
                        (progn
                          (funcall callback (beads-json-decode output))
                          (run-hooks 'beads-after-refresh-hook))
                      (beads-command-error
                       (setq failure
                             (append failure
                                     (list :json-error (cadr json-error))))
                       (beads--record-error failure)
                       (when error-callback (funcall error-callback failure))
                       (run-hooks 'beads-refresh-error-hook)))
                  (beads--record-error failure)
                  (when error-callback (funcall error-callback failure))
                  (run-hooks 'beads-refresh-error-hook)))))
        (when (buffer-live-p stdout) (kill-buffer stdout))
        (when (buffer-live-p stderr) (kill-buffer stderr))))))

(defun beads-command-async (program arguments callback
                                    &optional error-callback workspace buffer)
  "Run PROGRAM asynchronously with ARGUMENTS and decode its JSON output.
CALLBACK receives decoded data in BUFFER, which defaults to the current
buffer.  ERROR-CALLBACK receives the `beads-command-error' diagnostic plist.
WORKSPACE selects the command directory explicitly.
A newer request in the same buffer supersedes this one.  Return the process."
  (unless (and (stringp program) (listp arguments)
               (seq-every-p #'stringp arguments))
    (error "PROGRAM must be a string and ARGUMENTS a list of strings"))
  (let* ((target (or buffer (current-buffer)))
         (root (with-current-buffer target (beads-workspace-root workspace)))
         (argv (append (beads--database-arguments root) arguments))
         (stdout (generate-new-buffer " *Beads async stdout*"))
         (stderr (generate-new-buffer " *Beads async stderr*"))
         generation process)
    (with-current-buffer target
      (setq generation (cl-incf beads--request-generation))
      (beads-cancel-request target)
      (add-hook 'kill-buffer-hook #'beads--kill-owned-process nil t)
      (run-hooks 'beads-before-refresh-hook))
    (let ((default-directory root))
      (condition-case process-error
          (let ((executable (beads--resolve-executable program)))
            (setq process
                  (make-process
                   :name (format "beads-%d" generation)
                   :buffer stdout :stderr stderr :noquery t
                   :command (cons executable argv)
                   :sentinel
                   (lambda (proc _event)
                     (beads--async-finished
                      proc target generation program argv root stdout stderr
                      callback error-callback)))))
        (file-error
         (let ((data (list :program program :arguments argv :workspace root
                           :status 'file-error
                           :stderr (error-message-string process-error))))
           (kill-buffer stdout)
           (kill-buffer stderr)
           (with-current-buffer target
             (when (= generation beads--request-generation)
               (setq beads--active-process nil)
               (beads--record-error data)
               (when error-callback (funcall error-callback data))
               (run-hooks 'beads-refresh-error-hook)))
           (signal 'beads-command-error (list data))))))
    (with-current-buffer target (setq beads--active-process process))
    process))

(defun beads-br-async (arguments callback &optional error-callback workspace buffer)
  "Run br asynchronously with ARGUMENTS, invoking CALLBACK with JSON data.
ERROR-CALLBACK, WORKSPACE, and BUFFER are as in `beads-command-async'."
  (beads-command-async beads-br-executable arguments callback
                       error-callback workspace buffer))

(defun beads-bv-async (arguments callback &optional error-callback workspace buffer)
  "Run bv asynchronously with ARGUMENTS, invoking CALLBACK with JSON data.
ERROR-CALLBACK, WORKSPACE, and BUFFER are as in `beads-command-async'."
  (beads-command-async beads-bv-executable arguments callback
                       error-callback workspace buffer))

(provide 'beads-core)

;;; beads-core.el ends here
