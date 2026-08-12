;;; bv-core-test.el --- Tests for bv-core  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'bv-core)

(defmacro bv-core-test--workspace (&rest body)
  "Run BODY in a temporary Beads workspace."
  (declare (indent 0) (debug t))
  `(let ((root (make-temp-file "bv-core-test-" t)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name ".beads" root))
           (let ((default-directory root)
                 (bv-workspace nil)
                 (bv-default-workspace nil)
                 (bv-database-file nil))
             ,@body))
       (delete-directory root t))))

(ert-deftest bv-core-workspace-discovery-and-precedence ()
  (bv-core-test--workspace
    (let ((nested (expand-file-name "one/two" root)))
      (make-directory nested t)
      (let ((default-directory nested))
        (should (equal (bv-workspace-root)
                       (file-name-as-directory (file-truename root))))))
    (let ((bv-default-workspace root)
          (default-directory temporary-file-directory))
      (should (equal (bv-workspace-root)
                     (file-name-as-directory (file-truename root)))))))

(ert-deftest bv-core-json-normalizes-and-accesses-keys ()
  (let ((data (bv-json-decode
               "{\"issues\":[{\"id\":\"x-1\",\"closed\":false}],\"extra\":4}")))
    (should (equal (bv-object-get (car (bv-json-issues data)) 'id) "x-1"))
    (should (eq (bv-object-get (car (bv-json-issues data)) "closed")
                :json-false))
    (should (= (bv-object-get data 'extra) 4))
    (should (bv-object-member-p data "issues"))
    (should (eq (bv-object-get data 'absent 'fallback) 'fallback))))

(ert-deftest bv-core-json-issues-handles-empty-envelope ()
  (should-not (bv-json-issues (bv-json-decode "{\"issues\":[]}"))))

(ert-deftest bv-core-json-issues-handles-show-array ()
  (let ((issues (bv-json-issues
                 (bv-json-decode "[{\"id\":\"x-2\"},{\"id\":\"x-3\"}]"))))
    (should (= (length issues) 2))
    (should (equal (bv-object-get (car issues) "id") "x-2"))
    (should (equal (bv-object-get (cadr issues) "id") "x-3"))))

(ert-deftest bv-core-sync-uses-argv-workspace-and-database ()
  (bv-core-test--workspace
    (let ((bv-database-file "custom.db") captured)
      (cl-letf (((symbol-function 'process-file)
                 (lambda (program _in destination _display &rest arguments)
                   (setq captured (list program default-directory arguments))
                   (with-current-buffer (car destination)
                     (insert "{\"ok\":true}"))
                   0)))
        (should (eq (bv-object-get
                     (bv-command-sync "br" '("list" "--json")) "ok") t))
        (should (equal (car captured) "br"))
        (should (equal (cadr captured)
                       (file-name-as-directory (file-truename root))))
        (should (equal (caddr captured)
                       (list "--db" (expand-file-name
                                     "custom.db" (file-truename root))
                             "list" "--json")))))))

(ert-deftest bv-core-sync-wraps-missing-executable ()
  (bv-core-test--workspace
    (let ((bv-error-buffer-name " *bv missing executable*"))
      (unwind-protect
          (cl-letf (((symbol-function 'process-file)
                     (lambda (&rest _arguments)
                       (signal 'file-missing '("Not found" "no-br")))))
            (let ((error-data
                   (should-error (bv-command-sync "no-br" '("list" "--json"))
                                 :type 'bv-command-error)))
              (should (eq (plist-get (cadr error-data) :status) 'file-error))
              (should (string-match-p "Not found"
                                      (plist-get (cadr error-data) :stderr)))))
        (when (get-buffer bv-error-buffer-name)
          (kill-buffer bv-error-buffer-name))))))

(ert-deftest bv-core-sync-contextualizes-invalid-json ()
  (bv-core-test--workspace
    (let ((bv-error-buffer-name " *bv invalid json*"))
      (unwind-protect
          (cl-letf (((symbol-function 'process-file)
                     (lambda (_program _in destination _display &rest _args)
                       (with-current-buffer (car destination) (insert "oops"))
                       0)))
            (let ((error-data
                   (should-error (bv-command-sync "br" '("list" "--json"))
                                 :type 'bv-json-error)))
              (should (equal (plist-get (cadr error-data) :program) "br"))
              (should (equal (plist-get (cadr error-data) :stdout) "oops"))))
        (when (get-buffer bv-error-buffer-name)
          (kill-buffer bv-error-buffer-name))))))

(ert-deftest bv-core-sync-signals-rich-command-error ()
  (bv-core-test--workspace
    (let ((bv-error-buffer-name " *bv test errors*"))
      (unwind-protect
          (cl-letf (((symbol-function 'process-file)
                     (lambda (_program _in destination _display &rest _args)
                       (with-temp-file (cadr destination) (insert "bad option"))
                       2)))
            (let ((error-data
                   (should-error (bv-command-sync "br" '("list" "--json"))
                                 :type 'bv-command-error)))
              (should (= (plist-get (cadr error-data) :status) 2))
              (should (equal (plist-get (cadr error-data) :stderr)
                             "bad option"))))
        (when (get-buffer bv-error-buffer-name)
          (kill-buffer bv-error-buffer-name))))))

(ert-deftest bv-core-async-supersedes-stale-request ()
  (bv-core-test--workspace
    (let ((target (generate-new-buffer " *bv async target*"))
          processes callbacks)
      (unwind-protect
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest properties)
                       (let ((process (list properties)))
                         (push process processes)
                         process)))
                    ((symbol-function 'process-live-p) (lambda (_process) nil))
                    ((symbol-function 'process-status) (lambda (_process) 'exit))
                    ((symbol-function 'process-exit-status) (lambda (_process) 0)))
            (with-current-buffer target
              (setq-local default-directory root)
              (bv-command-async "br" '("list" "--json")
                                (lambda (_data) (push 'old callbacks)))
              (bv-command-async "br" '("ready" "--json")
                                (lambda (_data) (push 'new callbacks)))
              (should (= bv--request-generation 2))
              (should (eq bv--active-process (car processes))))
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

(provide 'bv-core-test)

;;; bv-core-test.el ends here
