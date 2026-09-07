;;; beads-test.el --- Tests for top-level Beads commands  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'test-helper)
(require 'beads-transient)

(ert-deftest beads-short-command-is-an-alias ()
  (should (eq (symbol-function 'bv) 'beads)))

(ert-deftest beads-opens-the-open-issue-list ()
  (let (opened-directory)
    (cl-letf (((symbol-function 'beads-list-open)
               (lambda (directory)
                 (setq opened-directory directory)
                 'open-list)))
      (should (eq (beads "/tmp/project/") 'open-list))
      (should (equal opened-directory "/tmp/project/")))))

(ert-deftest beads-menu-selects-the-current-buffer-menu ()
  (let (selected)
    (cl-letf (((symbol-function 'beads-list-menu)
               (lambda () (interactive) (setq selected 'list)))
              ((symbol-function 'beads-show-menu)
               (lambda () (interactive) (setq selected 'show)))
              ((symbol-function 'beads-triage-menu)
               (lambda () (interactive) (setq selected 'triage)))
              ((symbol-function 'beads-general-menu)
               (lambda () (interactive) (setq selected 'general))))
      (dolist (case '((beads-list-mode . list)
                      (beads-show-mode . show)
                      (beads-triage-mode . triage)
                      (fundamental-mode . general)))
        (with-temp-buffer
          (setq selected nil)
          (funcall (car case))
          (beads-menu)
          (should (eq selected (cdr case))))))))

(ert-deftest beads-version-string-uses-version-argv-and-trims-output ()
  (let (captured)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (executable)
                 (should (equal executable "br"))
                 "/opt/bin/br"))
              ((symbol-function 'process-file)
               (lambda (program input destination display &rest arguments)
                 (setq captured
                       (list program input destination display arguments))
                 (insert "br version 0.8.1\n")
                 0)))
      (should (equal (beads--version-string "br") "br version 0.8.1")))
    (should (equal captured
                   '("/opt/bin/br" nil t nil ("--version"))))))

(ert-deftest beads-version-string-reports-missing-and-failing-programs ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_executable) nil)))
    (should-error (beads--version-string "missing-br") :type 'user-error))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_executable) "/opt/bin/bv"))
            ((symbol-function 'process-file)
             (lambda (&rest _arguments) 2)))
    (let ((error-data (should-error (beads--version-string "bv")
                                    :type 'user-error)))
      (should (string-match-p "--version failed with status 2"
                              (error-message-string error-data))))))

(ert-deftest beads-version-string-rejects-executable-paths ()
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_executable)
               (ert-fail "Path-valued configuration bypassed exec-path"))))
    (let ((error-data (should-error
                       (beads--version-string "/opt/homebrew/bin/br")
                       :type 'user-error)))
      (should (string-match-p "command name on exec-path"
                              (error-message-string error-data))))))

(ert-deftest beads-check-renders-both-versions-in-workspace ()
  (beads-test-with-workspace
   (let ((beads-br-executable "custom-br")
         (beads-bv-executable "custom-bv")
         calls)
     (unwind-protect
         (cl-letf (((symbol-function 'beads--version-string)
                    (lambda (executable)
                      (push (cons executable default-directory) calls)
                      (concat executable " 1.0"))))
           (beads-check root)
           (with-current-buffer "*Beads check*"
             (let ((text (buffer-string)))
               (should (string-match-p "Beads environment" text))
               (should (string-match-p
                        (regexp-quote
                         (concat "Workspace: "
                                 (file-name-as-directory
                                  (file-truename root))))
                        text))
               (should (string-match-p "br:        custom-br 1.0" text))
               (should (string-match-p "bv:        custom-bv 1.0" text))))
           (should (equal (mapcar #'car (nreverse calls))
                          '("custom-br" "custom-bv")))
           (should (seq-every-p
                    (lambda (call)
                      (equal (cdr call)
                             (file-name-as-directory (file-truename root))))
                    calls)))
       (when (get-buffer "*Beads check*")
         (kill-buffer "*Beads check*"))))))

(provide 'beads-test)

;;; beads-test.el ends here
