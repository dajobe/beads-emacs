;;; beads-core-test.el --- Tests for beads-core  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'beads-core)

(defmacro beads-core-test--workspace (&rest body)
  "Run BODY in a temporary Beads workspace."
  (declare (indent 0) (debug t))
  `(let ((root (make-temp-file "beads-core-test-" t)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name ".beads" root))
           (let ((default-directory root)
                 (beads-workspace nil)
                 (beads-default-workspace nil)
                 (beads-database-file nil))
             ,@body))
       (delete-directory root t))))

(ert-deftest beads-core-workspace-discovery-and-precedence ()
  (beads-core-test--workspace
   (let ((nested (expand-file-name "one/two" root)))
     (make-directory nested t)
     (let ((default-directory nested))
       (should (equal (beads-workspace-root)
                      (file-name-as-directory (file-truename root))))))
   (let ((beads-default-workspace root)
         (default-directory temporary-file-directory))
     (should (equal (beads-workspace-root)
                    (file-name-as-directory (file-truename root)))))))

(ert-deftest beads-core-json-normalizes-and-accesses-keys ()
  (let ((data (beads-json-decode
               "{\"issues\":[{\"id\":\"x-1\",\"closed\":false}],\"extra\":4}")))
    (should (equal (beads-object-get (car (beads-json-issues data)) 'id) "x-1"))
    (should (eq (beads-object-get (car (beads-json-issues data)) "closed")
                :json-false))
    (should (= (beads-object-get data 'extra) 4))
    (should (beads-object-member-p data "issues"))
    (should (eq (beads-object-get data 'absent 'fallback) 'fallback))))

(ert-deftest beads-core-json-issues-handles-empty-envelope ()
  (should-not (beads-json-issues (beads-json-decode "{\"issues\":[]}"))))

(ert-deftest beads-core-json-issues-handles-show-array ()
  (let ((issues (beads-json-issues
                 (beads-json-decode "[{\"id\":\"x-2\"},{\"id\":\"x-3\"}]"))))
    (should (= (length issues) 2))
    (should (equal (beads-object-get (car issues) "id") "x-2"))
    (should (equal (beads-object-get (cadr issues) "id") "x-3"))))

(ert-deftest beads-core-executable-resolution-requires-exec-path-name ()
  (let (lookups)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program)
                 (push program lookups)
                 (and (equal program "br") "/exec-path/bin/br"))))
      (should (equal (beads--resolve-executable "br") "/exec-path/bin/br"))
      (should-error (beads--resolve-executable "missing")
                    :type 'file-missing)
      (should-error (beads--resolve-executable "/opt/bin/br")
                    :type 'file-missing)
      (should-error (beads--resolve-executable "./br")
                    :type 'file-missing)
      (should (equal (nreverse lookups) '("br" "missing"))))))

(ert-deftest beads-core-sync-uses-argv-workspace-and-database ()
  (beads-core-test--workspace
   (let ((beads-database-file "custom.db") captured)
     (cl-letf (((symbol-function 'executable-find)
                (lambda (program)
                  (should (equal program "br"))
                  "/exec-path/bin/br"))
               ((symbol-function 'process-file)
                (lambda (program _in destination _display &rest arguments)
                  (setq captured (list program default-directory arguments))
                  (with-current-buffer (car destination)
                    (insert "{\"ok\":true}"))
                  0)))
       (should (eq (beads-object-get
                    (beads-command-sync "br" '("list" "--json")) "ok") t))
       (should (equal (car captured) "/exec-path/bin/br"))
       (should (equal (cadr captured)
                      (file-name-as-directory (file-truename root))))
       (should (equal (caddr captured)
                      (list "--db" (expand-file-name
                                    "custom.db" (file-truename root))
                            "list" "--json")))))))

(ert-deftest beads-core-sync-wraps-missing-executable ()
  (beads-core-test--workspace
   (let ((beads-error-buffer-name " *bv missing executable*"))
     (unwind-protect
         (cl-letf (((symbol-function 'process-file)
                    (lambda (&rest _arguments)
                      (signal 'file-missing '("Not found" "no-br")))))
           (let ((error-data
                  (should-error (beads-command-sync "no-br" '("list" "--json"))
                                :type 'beads-command-error)))
             (should (eq (plist-get (cadr error-data) :status) 'file-error))
             (should (string-match-p "Not found"
                                     (plist-get (cadr error-data) :stderr)))))
       (when (get-buffer beads-error-buffer-name)
         (kill-buffer beads-error-buffer-name))))))

(ert-deftest beads-core-sync-contextualizes-invalid-json ()
  (beads-core-test--workspace
   (let ((beads-error-buffer-name " *bv invalid json*"))
     (unwind-protect
         (cl-letf (((symbol-function 'executable-find)
                    (lambda (_program) "/exec-path/bin/br"))
                   ((symbol-function 'process-file)
                    (lambda (_program _in destination _display &rest _args)
                      (with-current-buffer (car destination) (insert "oops"))
                      0)))
           (let ((error-data
                  (should-error (beads-command-sync "br" '("list" "--json"))
                                :type 'beads-json-error)))
             (should (equal (plist-get (cadr error-data) :program) "br"))
             (should (equal (plist-get (cadr error-data) :stdout) "oops"))))
       (when (get-buffer beads-error-buffer-name)
         (kill-buffer beads-error-buffer-name))))))

(ert-deftest beads-core-sync-signals-rich-command-error ()
  (beads-core-test--workspace
   (let ((beads-error-buffer-name " *bv test errors*"))
     (unwind-protect
         (cl-letf (((symbol-function 'executable-find)
                    (lambda (_program) "/exec-path/bin/br"))
                   ((symbol-function 'process-file)
                    (lambda (_program _in destination _display &rest _args)
                      (with-temp-file (cadr destination) (insert "bad option"))
                      2)))
           (let ((error-data
                  (should-error (beads-command-sync "br" '("list" "--json"))
                                :type 'beads-command-error)))
             (should (= (plist-get (cadr error-data) :status) 2))
             (should (equal (plist-get (cadr error-data) :stderr)
                            "bad option"))))
       (when (get-buffer beads-error-buffer-name)
         (kill-buffer beads-error-buffer-name))))))

(ert-deftest beads-core-async-supersedes-stale-request ()
  (beads-core-test--workspace
   (let ((target (generate-new-buffer " *bv async target*"))
         processes callbacks)
     (unwind-protect
         (cl-letf (((symbol-function 'executable-find)
                    (lambda (_program) "/exec-path/bin/br"))
                   ((symbol-function 'make-process)
                    (lambda (&rest properties)
                      (let ((process (list properties)))
                        (push process processes)
                        process)))
                   ((symbol-function 'process-live-p) (lambda (_process) nil))
                   ((symbol-function 'process-status) (lambda (_process) 'exit))
                   ((symbol-function 'process-exit-status) (lambda (_process) 0)))
           (with-current-buffer target
             (setq-local default-directory root)
             (beads-command-async "br" '("list" "--json")
                                  (lambda (_data) (push 'old callbacks)))
             (beads-command-async "br" '("ready" "--json")
                                  (lambda (_data) (push 'new callbacks)))
             (should (= beads--request-generation 2))
             (should (eq beads--active-process (car processes))))
           (dolist (process processes)
             (with-current-buffer (plist-get (car process) :buffer)
               (insert "[]")))
           (funcall (plist-get (car (cadr processes)) :sentinel)
                    (cadr processes) "finished")
           (should-not callbacks)
           (funcall (plist-get (car (car processes)) :sentinel)
                    (car processes) "finished")
           (should (equal callbacks '(new))))
       (kill-buffer target)
       (dolist (process processes)
         (dolist (key '(:buffer :stderr))
           (let ((buffer (plist-get (car process) key)))
             (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(ert-deftest beads-core-jsonl-change-events-handle-replacement-and-legacy-names ()
  (should (beads--jsonl-change-event-p
           '(watch changed "/tmp/project/.beads/issues.jsonl")))
  (should (beads--jsonl-change-event-p
           '(watch renamed "/tmp/project/.beads/issues.jsonl.tmp"
                   "/tmp/project/.beads/issues.jsonl")))
  (should (beads--jsonl-change-event-p
           '(watch changed "/tmp/project/.beads/beads.jsonl")))
  (should-not (beads--jsonl-change-event-p
               '(watch changed "/tmp/project/.beads/metadata.json")))
  (should-not (beads--jsonl-change-event-p
               '(watch stopped "/tmp/project/.beads/issues.jsonl"))))

(ert-deftest beads-core-workspace-watch-is-buffer-owned-and-removable ()
  (beads-core-test--workspace
   (with-temp-file (expand-file-name ".beads/issues.jsonl" root)
     (insert ""))
   (with-temp-buffer
     (setq-local beads-workspace
                 (file-name-as-directory (file-truename root)))
     (let (added removed callback)
       (cl-letf (((symbol-function 'file-notify-add-watch)
                  (lambda (directory flags function)
                    (setq added (list directory flags)
                          callback function)
                    'watch-descriptor))
                 ((symbol-function 'file-notify-rm-watch)
                  (lambda (descriptor) (setq removed descriptor))))
         (should (eq (beads-watch-workspace #'ignore) 'watch-descriptor))
         (should
          (equal added
                 (list (expand-file-name ".beads/issues.jsonl"
                                         (file-truename root))
                       '(change attribute-change))))
         (should (functionp callback))
         (should (memq #'beads-unwatch-workspace kill-buffer-hook))
         (beads-unwatch-workspace)
         (should (eq removed 'watch-descriptor))
         (should-not beads--file-watch))))))

(ert-deftest beads-core-file-watch-callback-schedules-only-issue-changes ()
  (with-temp-buffer
    (let ((buffer (current-buffer)) captured)
      (cl-letf (((symbol-function 'beads--schedule-auto-refresh)
                 (lambda (target function)
                   (setq captured (list target function)))))
        (beads--file-watch-callback
         buffer #'ignore
         '(watch changed "/tmp/project/.beads/metadata.json"))
        (should-not captured)
        (beads--file-watch-callback
         buffer #'ignore
         '(watch changed "/tmp/project/.beads/issues.jsonl"))
        (should (equal captured (list buffer #'ignore)))))))

(ert-deftest beads-core-file-watch-restarts-after-issue-file-replacement ()
  (with-temp-buffer
    (let ((buffer (current-buffer)) scheduled)
      (setq beads--file-watch 'watch)
      (cl-letf (((symbol-function 'beads--schedule-auto-refresh)
                 (lambda (target function)
                   (setq scheduled (list target function)))))
        (beads--file-watch-callback
         buffer #'ignore
         '(watch renamed "/tmp/project/.beads/issues.jsonl"
                 "/tmp/project/.beads/issues.jsonl.old"))
        (should (equal scheduled (list buffer #'ignore)))
        (should beads--rewatch-needed)
        (should-not beads--file-watch)))))

(ert-deftest beads-core-auto-refresh-reinstalls-replaced-file-watch ()
  (let ((buffer (generate-new-buffer " *bv rewatch*"))
        removed readded)
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (&rest _ignored) nil))
                  ((symbol-function 'file-notify-rm-watch)
                   (lambda (descriptor) (setq removed descriptor)))
                  ((symbol-function 'beads--add-workspace-watch)
                   (lambda (target function)
                     (setq readded (list target function)))))
          (with-current-buffer buffer
            (setq beads--file-watch 'directory-watch
                  beads--rewatch-needed t))
          (beads--auto-refresh-now buffer #'ignore)
          (should (eq removed 'directory-watch))
          (should (equal readded (list buffer #'ignore)))
          (with-current-buffer buffer
            (should-not beads--rewatch-needed)
            (should-not beads--file-watch)))
      (kill-buffer buffer))))

(ert-deftest beads-core-auto-refresh-scheduling-debounces-events ()
  (with-temp-buffer
    (setq beads--auto-refresh-timer 'old-timer)
    (let (cancelled scheduled)
      (cl-letf (((symbol-function 'timerp) (lambda (_timer) t))
                ((symbol-function 'cancel-timer)
                 (lambda (timer) (setq cancelled timer)))
                ((symbol-function 'run-at-time)
                 (lambda (delay repeat function &rest arguments)
                   (setq scheduled (list delay repeat function arguments))
                   'new-timer)))
        (beads--schedule-auto-refresh (current-buffer) #'ignore)
        (should (eq cancelled 'old-timer))
        (should (equal scheduled
                       (list beads-auto-refresh-delay nil
                             #'beads--auto-refresh-now
                             (list (current-buffer) #'ignore))))
        (should (eq beads--auto-refresh-timer 'new-timer))))))

(ert-deftest beads-core-auto-refresh-runs-only-for-visible-idle-buffers ()
  (let ((buffer (generate-new-buffer " *bv auto refresh*"))
        (visible t)
        (active nil)
        (calls 0)
        rescheduled)
    (unwind-protect
        (cl-letf (((symbol-function 'get-buffer-window)
                   (lambda (&rest _ignored) visible))
                  ((symbol-function 'process-live-p)
                   (lambda (_process) active))
                  ((symbol-function 'beads--schedule-auto-refresh)
                   (lambda (target function)
                     (setq rescheduled (list target function)))))
          (with-current-buffer buffer
            (setq beads--auto-refresh-timer 'pending))
          (beads--auto-refresh-now buffer (lambda () (cl-incf calls)))
          (should (= calls 1))
          (with-current-buffer buffer
            (should-not beads--auto-refresh-timer))
          (setq visible nil)
          (beads--auto-refresh-now buffer (lambda () (cl-incf calls)))
          (should (= calls 1))
          (setq visible t
                active t)
          (let ((refresh-function (lambda () (cl-incf calls))))
            (beads--auto-refresh-now buffer refresh-function)
            (should (= calls 1))
            (should (equal rescheduled
                           (list buffer refresh-function)))))
      (kill-buffer buffer))))

(provide 'beads-core-test)

;;; beads-core-test.el ends here
