;;; bv-list-test.el --- Tests for bv-list  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'test-helper)
(require 'bv-list)

(ert-deftest bv-list-arguments-match-br-interface ()
  (with-temp-buffer
    (bv-list-mode)
    (dolist (case '((all . ("list" "--all" "--json"))
                    (ready . ("ready" "--json"))
                    (blocked . ("blocked" "--json"))))
      (setq bv-list-kind (car case))
      (should (equal (bv-list--args) (cdr case))))
    (setq bv-list-kind 'search
          bv-list-query "quoted words")
    (should (equal (bv-list--args)
                   '("search" "quoted words" "--json")))
    (setq bv-list-kind 'unknown)
    (should-error (bv-list--args))))

(ert-deftest bv-list-installs-list-object-envelope-and-renders-faces ()
  (with-temp-buffer
    (bv-list-mode)
    (setq bv-list-kind 'all
          bv-list--refresh-generation 3
          bv-list--busy t)
    (bv-list--success
     (current-buffer) 3
     (bv-test-json
      (concat
       "{\"issues\":["
       "{\"id\":\"bve-1\",\"title\":\"First\",\"priority\":0,"
       "\"status\":\"open\",\"issue_type\":\"task\","
       "\"assignee\":\"dave\"},"
       "{\"id\":\"bve-2\",\"title\":\"Second\",\"priority\":3,"
       "\"status\":\"closed\",\"issue_type\":\"bug\"}]}")))
    (should (= (length bv-list-issues) 2))
    (should-not bv-list--busy)
    (should (equal header-line-format "2 issues"))
    (goto-char (point-min))
    (search-forward "P0")
    (should (eq (get-text-property (1- (point)) 'face)
                'bv-priority-0-face))
    (search-forward "open")
    (should (eq (get-text-property (1- (point)) 'face)
                'bv-status-open-face))
    (search-forward "P3")
    (should (eq (get-text-property (1- (point)) 'face)
                'bv-priority-low-face))
    (search-forward "closed")
    (should (eq (get-text-property (1- (point)) 'face)
                'bv-status-closed-face))))

(ert-deftest bv-list-ready-array-envelope-and-singular-header ()
  (with-temp-buffer
    (bv-list-mode)
    (setq bv-list-kind 'ready
          bv-list--refresh-generation 1)
    (bv-list--success
     (current-buffer) 1
     (bv-test-json
      "[{\"id\":\"bve-ready\",\"title\":\"Do it\",\"priority\":2,\"status\":\"in_progress\",\"issue_type\":\"task\"}]"))
    (should (equal header-line-format "1 issue"))
    (goto-char (point-min))
    (search-forward "in progress")
    (should (eq (get-text-property (1- (point)) 'face)
                'bv-status-progress-face))))

(ert-deftest bv-list-blocked-view-overrides-open-status-face ()
  (with-temp-buffer
    (bv-list-mode)
    (setq bv-list-kind 'blocked)
    (let ((status (bv-list--status-string
                   '(("status" . "open") ("blocked_by_count" . 0)))))
      (should (equal status "open"))
      (should (eq (get-text-property 0 'face status)
                  'bv-status-blocked-face)))))

(ert-deftest bv-list-refresh-preserves-selection-and-uses-workspace ()
  (bv-test-with-workspace
    (with-temp-buffer
      (bv-list-mode)
      (setq-local bv-workspace (file-name-as-directory (file-truename root)))
      (setq bv-list-kind 'all
            bv-list-issues
            (bv-test-json
             "[{\"id\":\"bve-a\",\"title\":\"A\",\"priority\":1},{\"id\":\"bve-b\",\"title\":\"B\",\"priority\":2}]"))
      (tabulated-list-print)
      (goto-char (point-min))
      (forward-line 1)
      (should (equal (tabulated-list-get-id) "bve-b"))
      (let (captured)
        (cl-letf (((symbol-function 'bv-br-async)
                   (lambda (arguments callback _error workspace buffer)
                     (setq captured (list arguments workspace buffer))
                     (funcall callback
                              (bv-test-json
                               "{\"issues\":[{\"id\":\"bve-b\",\"title\":\"Changed\",\"priority\":2},{\"id\":\"bve-c\",\"title\":\"C\",\"priority\":3}]}")))))
          (bv-list-refresh))
        (should (equal (car captured) '("list" "--all" "--json")))
        (should (equal (cadr captured) bv-workspace))
        (should (eq (caddr captured) (current-buffer)))
        (should (equal (tabulated-list-get-id) "bve-b"))
        (should (= bv-list--refresh-generation 1))))))

(ert-deftest bv-list-stale-success-does-not-replace-newer-results ()
  (with-temp-buffer
    (bv-list-mode)
    (setq bv-list--refresh-generation 2
          bv-list-issues '((old . t))
          bv-list--busy t)
    (bv-list--success
     (current-buffer) 1
     (bv-test-json "{\"issues\":[{\"id\":\"stale\"}]}"))
    (should (equal bv-list-issues '((old . t))))
    (should bv-list--busy)))

(ert-deftest bv-list-failure-clears-busy-and-reports-error ()
  (with-temp-buffer
    (bv-list-mode)
    (setq bv-list--refresh-generation 4
          bv-list--busy t)
    (let (reported)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (setq reported (apply #'format format-string arguments)))))
        (bv-list--failure (current-buffer) 4 '(:stderr "bad flag")))
      (should-not bv-list--busy)
      (should (string-match-p "Beads refresh failed" reported))
      (should (string-match-p "bad flag" reported)))))

(ert-deftest bv-list-refresh-rejects-unrelated-buffer ()
  (with-temp-buffer
    (should-error (bv-list-refresh) :type 'user-error)))

(provide 'bv-list-test)

;;; bv-list-test.el ends here
