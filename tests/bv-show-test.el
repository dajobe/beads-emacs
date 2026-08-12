;;; bv-show-test.el --- Tests for bv-show  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'test-helper)
(require 'bv-show)

(defconst bv-show-test--issue-json
  (concat
   "[{\"id\":\"bve-main\",\"title\":\"Main issue\","
   "\"status\":\"in_progress\",\"priority\":1,\"issue_type\":\"feature\","
   "\"assignee\":\"dave\",\"labels\":[\"emacs\",\"ui\"],"
   "\"description\":\"Description text\","
   "\"acceptance_criteria\":\"Acceptance text\","
   "\"dependencies\":[{\"id\":\"bve-dep\",\"title\":\"Dependency\","
   "\"dependency_type\":\"blocks\"}],"
   "\"dependents\":[{\"id\":\"bve-child\",\"title\":\"Child\"}],"
   "\"comments\":[{\"author\":\"alice\","
   "\"created_at\":\"2026-08-11\",\"text\":\"Looks good\"}],"
   "\"created_at\":\"2026-08-10\",\"updated_at\":\"2026-08-11\"}]" )
  "Representative array envelope emitted by `br show --json'.")

(ert-deftest bv-show-refresh-uses-exact-argv-and-array-envelope ()
  (bv-test-with-workspace
    (with-temp-buffer
      (bv-show-mode)
      (setq-local bv-workspace (file-name-as-directory (file-truename root)))
      (setq-local bv-show-id "bve-main")
      (let (captured)
        (cl-letf (((symbol-function 'bv-br-async)
                   (lambda (arguments callback _error workspace buffer)
                     (setq captured (list arguments workspace buffer))
                     (funcall callback
                              (bv-test-json bv-show-test--issue-json)))))
          (bv-show-refresh))
        (should (equal (car captured)
                       '("show" "bve-main" "--json")))
        (should (equal (cadr captured) bv-workspace))
        (should (eq (caddr captured) (current-buffer)))
        (should (equal (bv-object-get bv-show-issue 'id) "bve-main"))
        (should-not bv-show--busy)
        (should (string-match-p "Main issue" (buffer-string)))))))

(ert-deftest bv-show-mode-enables-visual-word-wrapping ()
  (with-temp-buffer
    (bv-show-mode)
    (should visual-line-mode)
    (should word-wrap)
    (should-not truncate-lines)))

(ert-deftest bv-show-render-includes-details-relations-comments-and-faces ()
  (with-temp-buffer
    (bv-show-mode)
    (setq-local bv-workspace default-directory)
    (bv-show-render (car (bv-json-issues
                          (bv-test-json bv-show-test--issue-json))))
    (let ((text (buffer-string)))
      (dolist (fragment '("Main issue" "Status: in_progress" "Priority: P1"
                          "Labels: emacs, ui" "Description text"
                          "Acceptance text" "Depends on" "bve-dep  Dependency"
                          "[blocks]" "Unblocks" "bve-child  Child" "Comments"
                          "alice  2026-08-11" "Looks good" "History"))
        (should (string-match-p (regexp-quote fragment) text))))
    (goto-char (point-min))
    (search-forward "in_progress")
    (should (eq (get-text-property (1- (point)) 'face)
                'bv-status-progress-face))
    (goto-char (point-min))
    (search-forward "alice")
    (should (eq (get-text-property (1- (point)) 'face) 'bv-muted-face))
    (goto-char (point-min))
    (search-forward "bve-dep")
    (let ((button (button-at (1- (point)))))
      (should button)
      (should (equal (button-get button 'bv-issue-id) "bve-dep")))))

(ert-deftest bv-show-comments-accept-installed-content-and-body-fields ()
  (with-temp-buffer
    (bv-show-mode)
    (let ((inhibit-read-only t))
      (bv-show--insert-comments
       (bv-test-json
        "[{\"created_by\":\"bob\",\"content\":\"Content form\"},{\"author\":\"eve\",\"body\":\"Body form\"}]")))
    (should (string-match-p "bob.*Content form" (buffer-string)))
    (should (string-match-p "eve.*Body form" (buffer-string)))))

(ert-deftest bv-show-empty-array-is-json-error ()
  (with-temp-buffer
    (bv-show-mode)
    (setq-local bv-show-id "missing")
    (setq-local bv-workspace default-directory)
    (cl-letf (((symbol-function 'bv-br-async)
               (lambda (_arguments callback _error _workspace _buffer)
                 (funcall callback (bv-test-json "[]")))))
      (should-error (bv-show-refresh) :type 'bv-json-error))))

(ert-deftest bv-show-failure-clears-busy-and-preserves-rendered-issue ()
  (with-temp-buffer
    (bv-show-mode)
    (setq-local bv-show-id "bve-main")
    (setq-local bv-workspace default-directory)
    (let ((inhibit-read-only t))
      (insert "Existing details"))
    (let (reported)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (setq reported (apply #'format format-string arguments))))
                ((symbol-function 'bv-br-async)
                 (lambda (_arguments _callback error-callback
                          _workspace _buffer)
                   (funcall error-callback '(:stderr "not found")))))
        (bv-show-refresh))
      (should-not bv-show--busy)
      (should (equal (buffer-string) "Existing details"))
      (should (string-match-p "Could not load issue bve-main" reported)))))

(ert-deftest bv-show-button-opens-selected-issue-in-same-workspace ()
  (with-temp-buffer
    (setq-local bv-workspace "/tmp/beads/")
    (let (opened)
      (cl-letf (((symbol-function 'bv-show)
                 (lambda (id workspace) (setq opened (list id workspace)))))
        (let ((button (list 'bv-issue-id "bve-other"
                            'bv-workspace bv-workspace)))
          (cl-letf (((symbol-function 'button-get)
                     (lambda (_button property)
                       (plist-get button property))))
            (bv-show--button-action button))))
      (should (equal opened '("bve-other" "/tmp/beads/"))))))

(ert-deftest bv-show-refresh-rejects-wrong-buffer-and-empty-id ()
  (with-temp-buffer
    (should-error (bv-show-refresh) :type 'user-error))
  (should-error (bv-show "") :type 'user-error))

(ert-deftest bv-show-issue-candidates-use-all-issues-and-display-titles ()
  (let (captured)
    (cl-letf (((symbol-function 'bv-br-sync)
               (lambda (arguments workspace)
                 (setq captured (list arguments workspace))
                 (bv-test-json
                  "{\"issues\":[{\"id\":\"bve-one\",\"title\":\"First issue\"},{\"id\":\"bve-two\",\"title\":\"\"}]}"))))
      (should
       (equal (bv-show--issue-candidates "/tmp/beads/")
              '(("bve-one  First issue" . "bve-one")
                ("bve-two" . "bve-two"))))
      (should (equal captured
                     '(("list" "--all" "--json") "/tmp/beads/"))))))

(ert-deftest bv-show-read-id-requires-a-candidate-and-returns-its-id ()
  (let (captured)
    (cl-letf (((symbol-function 'bv-show--issue-candidates)
               (lambda (_workspace)
                 '(("bve-one  First issue" . "bve-one"))))
              ((symbol-function 'completing-read)
               (lambda (prompt collection predicate require-match
                               &rest _ignored)
                 (setq captured
                       (list prompt collection predicate require-match))
                 "bve-one  First issue")))
      (should (equal (bv-show--read-id "/tmp/beads/") "bve-one"))
      (should (equal captured
                     '("Issue: "
                       (("bve-one  First issue" . "bve-one")) nil t))))))

(ert-deftest bv-show-read-id-rejects-a-workspace-without-issues ()
  (cl-letf (((symbol-function 'bv-show--issue-candidates)
             (lambda (_workspace) nil)))
    (should-error (bv-show--read-id "/tmp/beads/") :type 'user-error)))

(ert-deftest bv-show-interactive-completes-in-the-active-workspace ()
  (let ((workspace "/tmp/beads/")
        read-workspace
        watched
        opened-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'bv-workspace-root)
                   (lambda (&optional _directory) workspace))
                  ((symbol-function 'bv-show--read-id)
                   (lambda (root)
                     (setq read-workspace root)
                     "bve-one"))
                  ((symbol-function 'bv-show-refresh) #'ignore)
                  ((symbol-function 'bv-watch-workspace)
                   (lambda (function) (setq watched function)))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _ignored)
                     (setq opened-buffer buffer))))
          (let ((buffer (call-interactively #'bv-show)))
            (should (eq buffer opened-buffer))
            (should (equal read-workspace workspace))
            (should (eq watched #'bv-show-refresh))
            (with-current-buffer buffer
              (should (equal bv-show-id "bve-one"))
              (should (equal bv-workspace workspace)))))
      (when (buffer-live-p opened-buffer)
        (kill-buffer opened-buffer)))))

(provide 'bv-show-test)

;;; bv-show-test.el ends here
