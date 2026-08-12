;;; bv-test.el --- Tests for top-level bv commands  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'test-helper)
(require 'bv-transient)

(ert-deftest bv-menu-selects-the-current-buffer-menu ()
  (let (selected)
    (cl-letf (((symbol-function 'bv-list-menu)
               (lambda () (interactive) (setq selected 'list)))
              ((symbol-function 'bv-show-menu)
               (lambda () (interactive) (setq selected 'show)))
              ((symbol-function 'bv-triage-menu)
               (lambda () (interactive) (setq selected 'triage)))
              ((symbol-function 'bv-general-menu)
               (lambda () (interactive) (setq selected 'general))))
      (dolist (case '((bv-list-mode . list)
                      (bv-show-mode . show)
                      (bv-triage-mode . triage)
                      (fundamental-mode . general)))
        (with-temp-buffer
          (setq selected nil)
          (funcall (car case))
          (bv-menu)
          (should (eq selected (cdr case))))))))

(ert-deftest bv-version-string-uses-version-argv-and-trims-output ()
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
      (should (equal (bv--version-string "br") "br version 0.8.1")))
    (should (equal captured
                   '("/opt/bin/br" nil t nil ("--version"))))))

(ert-deftest bv-version-string-reports-missing-and-failing-programs ()
  (cl-letf (((symbol-function 'executable-find) (lambda (_executable) nil)))
    (should-error (bv--version-string "missing-br") :type 'user-error))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_executable) "/opt/bin/bv"))
            ((symbol-function 'process-file)
             (lambda (&rest _arguments) 2)))
    (let ((error-data (should-error (bv--version-string "bv")
                                    :type 'user-error)))
      (should (string-match-p "--version failed with status 2"
                              (error-message-string error-data))))))

(ert-deftest bv-check-renders-both-versions-in-workspace ()
  (bv-test-with-workspace
    (let ((bv-br-executable "custom-br")
          (bv-bv-executable "custom-bv")
          calls)
      (unwind-protect
          (cl-letf (((symbol-function 'bv--version-string)
                     (lambda (executable)
                       (push (cons executable default-directory) calls)
                       (concat executable " 1.0"))))
            (bv-check root)
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

(provide 'bv-test)

;;; bv-test.el ends here
