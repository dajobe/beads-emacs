;;; bv-edit-test.el --- Tests for bv-edit  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'test-helper)
(require 'bv-edit)

(defmacro bv-edit-test--capture-mutation (binding &rest body)
  "Run BODY and bind BINDING to arguments passed to the mutation boundary."
  (declare (indent 1) (debug (symbolp body)))
  `(let (,binding)
     (cl-letf (((symbol-function 'bv-edit--mutate)
                (lambda (arguments workspace action &optional callback)
                  (setq ,binding (list arguments workspace action callback)))))
       ,@body)
     ,binding))

(ert-deftest bv-edit-known-issues-uses-list-all-object-envelope ()
  (let (captured)
    (cl-letf (((symbol-function 'bv-br-sync)
               (lambda (arguments workspace)
                 (setq captured (list arguments workspace))
                 (bv-test-json
                  "{\"issues\":[{\"id\":\"bve-1\",\"title\":\"One\"}]}"))))
      (let ((issues (bv-edit--known-issues "/tmp/work/")))
        (should (equal captured
                       '(("list" "--all" "--json") "/tmp/work/")))
        (should (equal (bv-object-get (car issues) 'id) "bve-1"))))))

(ert-deftest bv-edit-create-builds-exact-command ()
  (bv-test-with-workspace
    (let ((answers '("New issue" "Description")))
      (let ((call
             (cl-letf (((symbol-function 'read-string)
                        (lambda (&rest _arguments) (pop answers)))
                       ((symbol-function 'bv-edit--read-choice)
                        (lambda (prompt _choices &optional _default)
                          (if (string-prefix-p "Type" prompt) "feature" "1"))))
               (bv-edit-test--capture-mutation captured
                 (bv-create root)))))
        (should (equal (car call)
                       '("create" "New issue" "--type" "feature"
                         "--priority" "1" "--description" "Description"
                         "--json")))
        (should (string= (cadr call)
                         (file-name-as-directory (file-truename root))))
        (should (equal (caddr call) "Created issue")))))
  (bv-test-with-workspace
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _args) "  "))
              ((symbol-function 'bv-edit--read-choice)
               (lambda (&rest _args) "task")))
      (should-error (bv-create root) :type 'user-error))))

(ert-deftest bv-edit-update-builds-field-specific-command ()
  (bv-test-with-workspace
    (let ((call
           (cl-letf (((symbol-function 'bv-edit--read-issue)
                      (lambda (_id _workspace)
                        '(("id" . "bve-2") ("priority" . 2))))
                     ((symbol-function 'bv-edit--read-choice)
                      (lambda (prompt _choices &optional _default)
                        (if (string-prefix-p "Field" prompt)
                            "priority"
                          "0"))))
             (bv-edit-test--capture-mutation captured
               (bv-update "bve-2" root)))))
      (should (equal (car call)
                     '("update" "bve-2" "--priority" "0" "--json")))
      (should (equal (caddr call) "Updated bve-2")))))

(ert-deftest bv-edit-claim-reopen-and-undefer-build-exact-commands ()
  (bv-test-with-workspace
    (let ((claim (bv-edit-test--capture-mutation captured
                   (bv-claim "bve-3" root))))
      (should (equal (car claim)
                     '("update" "bve-3" "--claim" "--json"))))
    (let ((reopen
           (cl-letf (((symbol-function 'read-string)
                      (lambda (&rest _args) "Needed again")))
             (bv-edit-test--capture-mutation captured
               (bv-reopen "bve-3" root)))))
      (should (equal (car reopen)
                     '("reopen" "bve-3" "--reason" "Needed again"
                       "--json"))))
    (let ((undefer (bv-edit-test--capture-mutation captured
                     (bv-undefer "bve-3" root))))
      (should (equal (car undefer)
                     '("undefer" "bve-3" "--json"))))))

(ert-deftest bv-edit-close-requires-confirmation-and-passes-reason ()
  (bv-test-with-workspace
    (let ((call
           (cl-letf (((symbol-function 'read-string)
                      (lambda (&rest _args) "Completed after review"))
                     ((symbol-function 'y-or-n-p)
                      (lambda (prompt)
                        (should (equal prompt "Close bve-4? "))
                        t)))
             (bv-edit-test--capture-mutation captured
               (bv-close "bve-4" root)))))
      (should (equal (car call)
                     '("close" "bve-4" "--reason"
                       "Completed after review" "--json"))))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _args) ""))
              ((symbol-function 'y-or-n-p) (lambda (&rest _args) nil)))
      (should-error (bv-close "bve-4" root) :type 'user-error))))

(ert-deftest bv-edit-defer-and-comment-reject-empty-values ()
  (bv-test-with-workspace
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _args) "  ")))
      (should-error (bv-defer "bve-5" root) :type 'user-error)
      (should-error (bv-add-comment "bve-5" root) :type 'user-error))
    (let ((defer
           (cl-letf (((symbol-function 'read-string)
                      (lambda (&rest _args) "+1w")))
             (bv-edit-test--capture-mutation captured
               (bv-defer "bve-5" root)))))
      (should (equal (car defer)
                     '("defer" "bve-5" "--until" "+1w" "--json"))))
    (let ((comment
           (cl-letf (((symbol-function 'read-string)
                      (lambda (&rest _args) "A useful comment")))
             (bv-edit-test--capture-mutation captured
               (bv-add-comment "bve-5" root)))))
      (should (equal (car comment)
                     '("comments" "add" "bve-5" "--message"
                       "A useful comment" "--json"))))))

(ert-deftest bv-edit-label-commands-use-installed-envelopes ()
  (bv-test-with-workspace
    (cl-letf (((symbol-function 'bv-br-sync)
               (lambda (_arguments _workspace)
                 (bv-test-json
                  "{\"labels\":[{\"name\":\"emacs\"},{\"label\":\"ui\"},\"docs\"]}"))))
      (should (equal (bv-edit--labels root) '("emacs" "ui" "docs"))))
    (let ((add
           (cl-letf (((symbol-function 'bv-edit--labels)
                      (lambda (_workspace) '("emacs" "ui")))
                     ((symbol-function 'completing-read)
                      (lambda (&rest _args) "ui")))
             (bv-edit-test--capture-mutation captured
               (bv-add-label "bve-6" root)))))
      (should (equal (car add)
                     '("label" "add" "bve-6" "--label" "ui" "--json"))))
    (let ((remove
           (cl-letf (((symbol-function 'bv-edit--read-issue)
                      (lambda (_id _workspace)
                        '(("labels" . ("emacs" "ui")))))
                     ((symbol-function 'completing-read)
                      (lambda (&rest _args) "emacs")))
             (bv-edit-test--capture-mutation captured
               (bv-remove-label "bve-6" root)))))
      (should (equal (car remove)
                     '("label" "remove" "bve-6" "--label" "emacs"
                       "--json"))))))

(ert-deftest bv-edit-dependency-add-and-confirmed-remove-command-lines ()
  (bv-test-with-workspace
    (let ((add
           (cl-letf (((symbol-function 'bv-edit--read-id)
                      (lambda (&rest _args) "bve-target"))
                     ((symbol-function 'bv-edit--read-choice)
                      (lambda (&rest _args) "waits-for")))
             (bv-edit-test--capture-mutation captured
               (bv-add-dependency "bve-source" root)))))
      (should (equal (car add)
                     '("dep" "add" "bve-source" "bve-target" "--type"
                       "waits-for" "--json"))))
    (let ((remove
           (cl-letf (((symbol-function 'bv-edit--read-issue)
                      (lambda (_id _workspace)
                        '(("dependencies" .
                           ((("id" . "bve-target")
                             ("title" . "Target")))))))
                     ((symbol-function 'completing-read)
                      (lambda (&rest _args) "bve-target  Target"))
                     ((symbol-function 'y-or-n-p)
                      (lambda (prompt)
                        (should (equal prompt
                                       "Remove dependency bve-source -> bve-target? "))
                        t)))
             (bv-edit-test--capture-mutation captured
               (bv-remove-dependency "bve-source" root)))))
      (should (equal (car remove)
                     '("dep" "remove" "bve-source" "bve-target" "--json"))))))

(ert-deftest bv-edit-remove-dependency-does-not-mutate-when-declined ()
  (bv-test-with-workspace
    (let ((mutated nil))
      (cl-letf (((symbol-function 'bv-edit--read-issue)
                 (lambda (_id _workspace)
                   '(("dependencies" .
                      ((("id" . "bve-target") ("title" . "Target")))))))
                ((symbol-function 'completing-read)
                 (lambda (&rest _args) "bve-target  Target"))
                ((symbol-function 'y-or-n-p) (lambda (&rest _args) nil))
                ((symbol-function 'bv-edit--mutate)
                 (lambda (&rest _args) (setq mutated t))))
        (bv-remove-dependency "bve-source" root))
      (should-not mutated))))

(ert-deftest bv-edit-mutate-reports-success-calls-back-and-refreshes ()
  (with-temp-buffer
    (let (async-arguments callback-value refreshed messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (push (apply #'format format-string arguments) messages)))
                ((symbol-function 'bv-br-async)
                 (lambda (arguments callback _error workspace buffer)
                   (setq async-arguments (list arguments workspace buffer))
                   (funcall callback '(("id" . "bve-new")))))
                ((symbol-function 'bv-edit--refresh-workspace)
                 (lambda (workspace) (setq refreshed workspace))))
        (bv-edit--mutate
         '("update" "bve-7" "--claim" "--json") "/tmp/work/"
         "Claimed bve-7"
         (lambda (json) (setq callback-value json))))
      (should (equal async-arguments
                     (list '("update" "bve-7" "--claim" "--json")
                           "/tmp/work/" (current-buffer))))
      (should (equal callback-value '(("id" . "bve-new"))))
      (should (equal refreshed "/tmp/work/"))
      (should (member "Claimed bve-7..." messages))
      (should (member "Claimed bve-7" messages)))))

(ert-deftest bv-edit-mutate-reports-concise-command-error ()
  (with-temp-buffer
    (let (reported)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (setq reported (apply #'format format-string arguments))))
                ((symbol-function 'bv-br-async)
                 (lambda (_arguments _callback error-callback
                          _workspace _buffer)
                   (funcall error-callback '(:stderr " bad command \n")))))
        (bv-edit--mutate '("bad") "/tmp/work/" "Changed issue"))
      (should (equal reported "Changed issue failed: bad command")))))

(provide 'bv-edit-test)

;;; bv-edit-test.el ends here
