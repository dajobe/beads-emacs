;;; beads-edit-test.el --- Tests for beads-edit  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'test-helper)
(require 'beads-edit)

(defmacro beads-edit-test--capture-mutation (binding &rest body)
  "Run BODY and bind BINDING to arguments passed to the mutation boundary."
  (declare (indent 1) (debug (symbolp body)))
  `(let (,binding)
     (cl-letf (((symbol-function 'beads-edit--mutate)
                (lambda (arguments workspace action &optional callback)
                  (setq ,binding (list arguments workspace action callback)))))
       ,@body)
     ,binding))

(ert-deftest beads-edit-known-issues-uses-list-all-object-envelope ()
  (let (captured)
    (cl-letf (((symbol-function 'beads-br-sync)
               (lambda (arguments workspace)
                 (setq captured (list arguments workspace))
                 (beads-test-json
                  "{\"issues\":[{\"id\":\"bve-1\",\"title\":\"One\"}]}"))))
      (let ((issues (beads-edit--known-issues "/tmp/work/")))
        (should (equal captured
                       '(("list" "--all" "--json") "/tmp/work/")))
        (should (equal (beads-object-get (car issues) 'id) "bve-1"))))))

(ert-deftest beads-edit-create-builds-exact-command ()
  (beads-test-with-workspace
   (let ((answers '("New issue" "Description")))
     (let ((call
            (cl-letf (((symbol-function 'read-string)
                       (lambda (&rest _arguments) (pop answers)))
                      ((symbol-function 'beads-edit--read-choice)
                       (lambda (prompt _choices &optional _default)
                         (if (string-prefix-p "Type" prompt) "feature" "1"))))
              (beads-edit-test--capture-mutation captured
                                                 (beads-create root)))))
       (should (equal (car call)
                      '("create" "New issue" "--type" "feature"
                        "--priority" "1" "--description" "Description"
                        "--json")))
       (should (string= (cadr call)
                        (file-name-as-directory (file-truename root))))
       (should (equal (caddr call) "Created issue")))))
  (beads-test-with-workspace
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _args) "  "))
             ((symbol-function 'beads-edit--read-choice)
              (lambda (&rest _args) "task")))
     (should-error (beads-create root) :type 'user-error))))

(ert-deftest beads-edit-update-builds-field-specific-command ()
  (beads-test-with-workspace
   (let ((call
          (cl-letf (((symbol-function 'beads-edit--read-issue)
                     (lambda (_id _workspace)
                       '(("id" . "bve-2") ("priority" . 2))))
                    ((symbol-function 'beads-edit--read-choice)
                     (lambda (prompt _choices &optional _default)
                       (if (string-prefix-p "Field" prompt)
                           "priority"
                         "0"))))
            (beads-edit-test--capture-mutation captured
                                               (beads-update "bve-2" root)))))
     (should (equal (car call)
                    '("update" "bve-2" "--priority" "0" "--json")))
     (should (equal (caddr call) "Updated bve-2")))))

(ert-deftest beads-edit-claim-reopen-and-undefer-build-exact-commands ()
  (beads-test-with-workspace
   (let ((claim (beads-edit-test--capture-mutation captured
                                                   (beads-claim "bve-3" root))))
     (should (equal (car claim)
                    '("update" "bve-3" "--claim" "--json"))))
   (let ((reopen
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _args) "Needed again")))
            (beads-edit-test--capture-mutation captured
                                               (beads-reopen "bve-3" root)))))
     (should (equal (car reopen)
                    '("reopen" "bve-3" "--reason" "Needed again"
                      "--json"))))
   (let ((undefer (beads-edit-test--capture-mutation captured
                                                     (beads-undefer "bve-3" root))))
     (should (equal (car undefer)
                    '("undefer" "bve-3" "--json"))))))

(ert-deftest beads-edit-close-requires-confirmation-and-passes-reason ()
  (beads-test-with-workspace
   (let ((call
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _args) "Completed after review"))
                    ((symbol-function 'y-or-n-p)
                     (lambda (prompt)
                       (should (equal prompt "Close bve-4? "))
                       t)))
            (beads-edit-test--capture-mutation captured
                                               (beads-close "bve-4" root)))))
     (should (equal (car call)
                    '("close" "bve-4" "--reason"
                      "Completed after review" "--json"))))
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _args) ""))
             ((symbol-function 'y-or-n-p) (lambda (&rest _args) nil)))
     (should-error (beads-close "bve-4" root) :type 'user-error))))

(ert-deftest beads-edit-defer-and-comment-reject-empty-values ()
  (beads-test-with-workspace
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _args) "  ")))
     (should-error (beads-defer "bve-5" root) :type 'user-error)
     (should-error (beads-add-comment "bve-5" root) :type 'user-error))
   (let ((defer
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _args) "+1w")))
            (beads-edit-test--capture-mutation captured
                                               (beads-defer "bve-5" root)))))
     (should (equal (car defer)
                    '("defer" "bve-5" "--until" "+1w" "--json"))))
   (let ((comment
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _args) "A useful comment")))
            (beads-edit-test--capture-mutation captured
                                               (beads-add-comment "bve-5" root)))))
     (should (equal (car comment)
                    '("comments" "add" "bve-5" "--message"
                      "A useful comment" "--json"))))))

(ert-deftest beads-edit-label-commands-use-installed-envelopes ()
  (beads-test-with-workspace
   (cl-letf (((symbol-function 'beads-br-sync)
              (lambda (_arguments _workspace)
                (beads-test-json
                 "{\"labels\":[{\"name\":\"emacs\"},{\"label\":\"ui\"},\"docs\"]}"))))
     (should (equal (beads-edit--labels root) '("emacs" "ui" "docs"))))
   (let ((add
          (cl-letf (((symbol-function 'beads-edit--labels)
                     (lambda (_workspace) '("emacs" "ui")))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _args) "ui")))
            (beads-edit-test--capture-mutation captured
                                               (beads-add-label "bve-6" root)))))
     (should (equal (car add)
                    '("label" "add" "bve-6" "--label" "ui" "--json"))))
   (let ((remove
          (cl-letf (((symbol-function 'beads-edit--read-issue)
                     (lambda (_id _workspace)
                       '(("labels" . ("emacs" "ui")))))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _args) "emacs")))
            (beads-edit-test--capture-mutation captured
                                               (beads-remove-label "bve-6" root)))))
     (should (equal (car remove)
                    '("label" "remove" "bve-6" "--label" "emacs"
                      "--json"))))))

(ert-deftest beads-edit-dependency-add-and-confirmed-remove-command-lines ()
  (beads-test-with-workspace
   (let ((add
          (cl-letf (((symbol-function 'beads-edit--read-id)
                     (lambda (&rest _args) "bve-target"))
                    ((symbol-function 'beads-edit--read-choice)
                     (lambda (&rest _args) "waits-for")))
            (beads-edit-test--capture-mutation captured
                                               (beads-add-dependency "bve-source" root)))))
     (should (equal (car add)
                    '("dep" "add" "bve-source" "bve-target" "--type"
                      "waits-for" "--json"))))
   (let ((remove
          (cl-letf (((symbol-function 'beads-edit--read-issue)
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
            (beads-edit-test--capture-mutation captured
                                               (beads-remove-dependency "bve-source" root)))))
     (should (equal (car remove)
                    '("dep" "remove" "bve-source" "bve-target" "--json"))))))

(ert-deftest beads-edit-remove-dependency-does-not-mutate-when-declined ()
  (beads-test-with-workspace
   (let ((mutated nil))
     (cl-letf (((symbol-function 'beads-edit--read-issue)
                (lambda (_id _workspace)
                  '(("dependencies" .
                     ((("id" . "bve-target") ("title" . "Target")))))))
               ((symbol-function 'completing-read)
                (lambda (&rest _args) "bve-target  Target"))
               ((symbol-function 'y-or-n-p) (lambda (&rest _args) nil))
               ((symbol-function 'beads-edit--mutate)
                (lambda (&rest _args) (setq mutated t))))
       (beads-remove-dependency "bve-source" root))
     (should-not mutated))))

(ert-deftest beads-edit-mutate-reports-success-calls-back-and-refreshes ()
  (with-temp-buffer
    (let (async-arguments callback-value refreshed messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (push (apply #'format format-string arguments) messages)))
                ((symbol-function 'beads-br-async)
                 (lambda (arguments callback _error workspace buffer)
                   (setq async-arguments (list arguments workspace buffer))
                   (funcall callback '(("id" . "bve-new")))))
                ((symbol-function 'beads-edit--refresh-workspace)
                 (lambda (workspace) (setq refreshed workspace))))
        (beads-edit--mutate
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

(ert-deftest beads-edit-mutate-reports-concise-command-error ()
  (with-temp-buffer
    (let (reported)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (setq reported (apply #'format format-string arguments))))
                ((symbol-function 'beads-br-async)
                 (lambda (_arguments _callback error-callback
                                     _workspace _buffer)
                   (funcall error-callback '(:stderr " bad command \n")))))
        (beads-edit--mutate '("bad") "/tmp/work/" "Changed issue"))
      (should (equal reported "Changed issue failed: bad command")))))

(provide 'beads-edit-test)

;;; beads-edit-test.el ends here
