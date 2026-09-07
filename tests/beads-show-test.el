;;; beads-show-test.el --- Tests for beads-show  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'test-helper)
(require 'beads-show)
(require 'beads-transient)

(ert-deftest beads-show-direct-bindings-are-documented-in-command-menu ()
  (dolist (binding '(("g" . beads-show-refresh)
                     ("e" . beads-update)
                     ("C" . beads-claim)
                     ("x" . beads-close)
                     ("R" . beads-reopen)
                     ("d" . beads-defer)
                     ("c" . beads-add-comment)
                     ("l a" . beads-add-label)
                     ("l r" . beads-remove-label)
                     ("D a" . beads-add-dependency)
                     ("D r" . beads-remove-dependency)))
    (should (beads-test-transient-key-invokes-command-p
             'beads-show-menu (car binding) (cdr binding)))))

(defconst beads-show-test--issue-json
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

(ert-deftest beads-show-refresh-uses-exact-argv-and-array-envelope ()
  (beads-test-with-workspace
   (with-temp-buffer
     (beads-show-mode)
     (setq-local beads-workspace (file-name-as-directory (file-truename root)))
     (setq-local beads-show-id "bve-main")
     (let (captured)
       (cl-letf (((symbol-function 'beads-br-async)
                  (lambda (arguments callback _error workspace buffer)
                    (setq captured (list arguments workspace buffer))
                    (funcall callback
                             (beads-test-json beads-show-test--issue-json)))))
         (beads-show-refresh))
       (should (equal (car captured)
                      '("show" "bve-main" "--json")))
       (should (equal (cadr captured) beads-workspace))
       (should (eq (caddr captured) (current-buffer)))
       (should (equal (beads-object-get beads-show-issue 'id) "bve-main"))
       (should-not beads-show--busy)
       (should (string-match-p "Main issue" (buffer-string)))))))

(ert-deftest beads-show-mode-enables-visual-word-wrapping ()
  (with-temp-buffer
    (beads-show-mode)
    (should visual-line-mode)
    (should word-wrap)
    (should-not truncate-lines)))

(ert-deftest beads-show-render-includes-details-relations-comments-and-faces ()
  (with-temp-buffer
    (beads-show-mode)
    (setq-local beads-workspace default-directory)
    (beads-show-render (car (beads-json-issues
                             (beads-test-json beads-show-test--issue-json))))
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
                'beads-status-progress-face))
    (goto-char (point-min))
    (search-forward "alice")
    (should (eq (get-text-property (1- (point)) 'face) 'beads-muted-face))
    (goto-char (point-min))
    (search-forward "bve-dep")
    (let ((button (button-at (1- (point)))))
      (should button)
      (should (equal (button-get button 'beads-issue-id) "bve-dep")))))

(ert-deftest beads-show-comments-accept-installed-content-and-body-fields ()
  (with-temp-buffer
    (beads-show-mode)
    (let ((inhibit-read-only t))
      (beads-show--insert-comments
       (beads-test-json
        "[{\"created_by\":\"bob\",\"content\":\"Content form\"},{\"author\":\"eve\",\"body\":\"Body form\"}]")))
    (should (string-match-p "bob.*Content form" (buffer-string)))
    (should (string-match-p "eve.*Body form" (buffer-string)))))

(ert-deftest beads-show-empty-array-is-json-error ()
  (with-temp-buffer
    (beads-show-mode)
    (setq-local beads-show-id "missing")
    (setq-local beads-workspace default-directory)
    (cl-letf (((symbol-function 'beads-br-async)
               (lambda (_arguments callback _error _workspace _buffer)
                 (funcall callback (beads-test-json "[]")))))
      (should-error (beads-show-refresh) :type 'beads-json-error))))

(ert-deftest beads-show-failure-clears-busy-and-preserves-rendered-issue ()
  (with-temp-buffer
    (beads-show-mode)
    (setq-local beads-show-id "bve-main")
    (setq-local beads-workspace default-directory)
    (let ((inhibit-read-only t))
      (insert "Existing details"))
    (let (reported)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (setq reported (apply #'format format-string arguments))))
                ((symbol-function 'beads-br-async)
                 (lambda (_arguments _callback error-callback
                                     _workspace _buffer)
                   (funcall error-callback '(:stderr "not found")))))
        (beads-show-refresh))
      (should-not beads-show--busy)
      (should (equal (buffer-string) "Existing details"))
      (should (string-match-p "Could not load issue bve-main" reported)))))

(ert-deftest beads-show-button-opens-selected-issue-in-same-workspace ()
  (with-temp-buffer
    (setq-local beads-workspace "/tmp/beads/")
    (let (opened)
      (cl-letf (((symbol-function 'beads-show)
                 (lambda (id workspace) (setq opened (list id workspace)))))
        (let ((button (list 'beads-issue-id "bve-other"
                            'beads-workspace beads-workspace)))
          (cl-letf (((symbol-function 'button-get)
                     (lambda (_button property)
                       (plist-get button property))))
            (beads-show--button-action button))))
      (should (equal opened '("bve-other" "/tmp/beads/"))))))

(ert-deftest beads-show-refresh-rejects-wrong-buffer-and-empty-id ()
  (with-temp-buffer
    (should-error (beads-show-refresh) :type 'user-error))
  (should-error (beads-show "") :type 'user-error))

(ert-deftest beads-show-issue-candidates-use-all-issues-and-display-titles ()
  (let (captured)
    (cl-letf (((symbol-function 'beads-br-sync)
               (lambda (arguments workspace)
                 (setq captured (list arguments workspace))
                 (beads-test-json
                  "{\"issues\":[{\"id\":\"bve-one\",\"title\":\"First issue\"},{\"id\":\"bve-two\",\"title\":\"\"}]}"))))
      (should
       (equal (beads-show--issue-candidates "/tmp/beads/")
              '(("bve-one  First issue" . "bve-one")
                ("bve-two" . "bve-two"))))
      (should (equal captured
                     '(("list" "--all" "--json") "/tmp/beads/"))))))

(ert-deftest beads-show-read-id-requires-a-candidate-and-returns-its-id ()
  (let (captured)
    (cl-letf (((symbol-function 'beads-show--issue-candidates)
               (lambda (_workspace)
                 '(("bve-one  First issue" . "bve-one"))))
              ((symbol-function 'completing-read)
               (lambda (prompt collection predicate require-match
                               &rest _ignored)
                 (setq captured
                       (list prompt collection predicate require-match))
                 "bve-one  First issue")))
      (should (equal (beads-show--read-id "/tmp/beads/") "bve-one"))
      (should (equal captured
                     '("Issue: "
                       (("bve-one  First issue" . "bve-one")) nil t))))))

(ert-deftest beads-show-read-id-rejects-a-workspace-without-issues ()
  (cl-letf (((symbol-function 'beads-show--issue-candidates)
             (lambda (_workspace) nil)))
    (should-error (beads-show--read-id "/tmp/beads/") :type 'user-error)))

(ert-deftest beads-show-interactive-completes-in-the-active-workspace ()
  (let ((workspace "/tmp/beads/")
        read-workspace
        watched
        opened-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'beads-workspace-root)
                   (lambda (&optional _directory) workspace))
                  ((symbol-function 'beads-show--read-id)
                   (lambda (root)
                     (setq read-workspace root)
                     "bve-one"))
                  ((symbol-function 'beads-show-refresh) #'ignore)
                  ((symbol-function 'beads-watch-workspace)
                   (lambda (function) (setq watched function)))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _ignored)
                     (setq opened-buffer buffer))))
          (let ((buffer (call-interactively #'beads-show)))
            (should (eq buffer opened-buffer))
            (should (equal read-workspace workspace))
            (should (eq watched #'beads-show-refresh))
            (with-current-buffer buffer
              (should (equal beads-show-id "bve-one"))
              (should (equal beads-workspace workspace)))))
      (when (buffer-live-p opened-buffer)
        (kill-buffer opened-buffer)))))

(ert-deftest beads-show-reuses-one-buffer-for-different-issues-and-workspaces ()
  (let ((workspace-one "/tmp/beads-one/")
        (workspace-two "/tmp/beads-two/")
        opened-buffers
        refreshes)
    (when-let* ((existing (get-buffer beads-show-buffer-name)))
      (kill-buffer existing))
    (unwind-protect
        (cl-letf (((symbol-function 'beads-workspace-root)
                   (lambda (&optional directory) directory))
                  ((symbol-function 'beads-show-refresh)
                   (lambda ()
                     (push (list beads-show-id beads-workspace) refreshes)))
                  ((symbol-function 'beads-watch-workspace) #'ignore)
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _ignored)
                     (push buffer opened-buffers))))
          (let ((first (beads-show "bve-one" workspace-one)))
            (with-current-buffer first
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert "First issue details")))
            (let ((second (beads-show "bve-two" workspace-two)))
              (should (eq first second))
              (should (equal (buffer-name second) beads-show-buffer-name))
              (should (equal opened-buffers (list second first)))
              (should (equal refreshes
                             `(("bve-two" ,workspace-two)
                               ("bve-one" ,workspace-one))))
              (with-current-buffer second
                (should (equal beads-show-id "bve-two"))
                (should (equal beads-workspace workspace-two))
                (should-not beads-show-issue)
                (should (equal (buffer-string)
                               "Loading issue bve-two...\n"))))))
      (when-let* ((buffer (get-buffer beads-show-buffer-name)))
        (kill-buffer buffer)))))

(provide 'beads-show-test)

;;; beads-show-test.el ends here
