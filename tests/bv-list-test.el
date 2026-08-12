;;; bv-list-test.el --- Tests for bv-list  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'test-helper)
(require 'bv-list)

(ert-deftest bv-list-arguments-match-br-interface ()
  (with-temp-buffer
    (bv-list-mode)
    (dolist (case '((all . ("list" "--all" "--json"))
                    (open . ("list" "--status" "open" "--json"))
                    (closed . ("list" "--status" "closed" "--json"))
                    (ready . ("ready" "--json"))
                    (blocked . ("blocked" "--json"))))
      (setq bv-list-kind (car case))
      (should (equal (bv-list--args) (cdr case))))
    (setq bv-list-kind 'search
          bv-list-query "quoted words")
    (should (equal (bv-list--args)
                   '("search" "quoted words" "--json")))
    (setq bv-list-kind 'label
          bv-list-query "frontend")
    (should (equal (bv-list--args)
                   '("list" "--all" "--label" "frontend" "--json")))
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
    (should (string-prefix-p "All — 2 issues    TYPE PRI STATUS ID TITLE"
                             (car header-line-format)))
    (goto-char (point-min))
    (search-forward "📋")
    (search-forward "P0")
    (should (eq (get-text-property (1- (point)) 'face)
                'bv-priority-0-face))
    (search-forward "OPEN")
    (should (eq (get-text-property (1- (point)) 'face)
                'bv-status-open-face))
    (search-forward "P3")
    (should (eq (get-text-property (1- (point)) 'face)
                'bv-priority-low-face))
    (search-forward "DONE")
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
    (should (string-prefix-p "Ready — 1 issue    TYPE PRI STATUS ID TITLE"
                             (car header-line-format)))
    (goto-char (point-min))
    (search-forward "PROG")
    (should (eq (get-text-property (1- (point)) 'face)
                'bv-status-progress-face))))

(ert-deftest bv-list-blocked-view-overrides-open-status-face ()
  (with-temp-buffer
    (bv-list-mode)
    (setq bv-list-kind 'blocked)
    (let ((status (bv-list--status-string
                   '(("status" . "open") ("blocked_by_count" . 0)))))
      (should (equal status "BLKD"))
      (should (eq (get-text-property 0 'face status)
                  'bv-status-blocked-face)))))

(ert-deftest bv-list-type-icons-explain-known-and-custom-types ()
  (dolist (case '(("bug" . "🐛")
                  ("feature" . "✨")
                  ("task" . "📋")
                  ("epic" . "🚀")
                  ("chore" . "🧹")
                  ("custom" . "•")))
    (let ((icon (bv-list--type-icon
                 `(("issue_type" . ,(car case))))))
      (should (equal icon (cdr case)))
      (should (equal (get-text-property 0 'help-echo icon)
                     (format "Type: %s" (car case)))))))

(ert-deftest bv-list-compact-status-labels-match-bv-vocabulary ()
  (dolist (case '(("open" . "OPEN")
                  ("in_progress" . "PROG")
                  ("blocked" . "BLKD")
                  ("closed" . "DONE")
                  ("deferred" . "DEFR")
                  ("draft" . "DRFT")
                  ("pinned" . "PIN")
                  ("hooked" . "HOOK")
                  ("review" . "REVW")
                  ("tombstone" . "TOMB")
                  ("custom" . "????")))
    (let ((bv-list-kind 'all))
      (should (equal (bv-list--status-string
                      `(("status" . ,(car case))))
                     (cdr case))))))

(ert-deftest bv-list-relative-time-has-compact-stable-boundaries ()
  (let ((now (date-to-time "2026-08-12T02:00:00Z")))
    (dolist (case '((0 . "now")
                    (59 . "now")
                    (60 . "1m ago")
                    (3599 . "59m ago")
                    (3600 . "1h ago")
                    (86399 . "23h ago")
                    (86400 . "1d ago")
                    (604800 . "1w ago")
                    (2592000 . "1mo ago")))
      (let ((timestamp
             (format-time-string
              "%Y-%m-%dT%H:%M:%SZ"
              (time-subtract now (seconds-to-time (car case))) t)))
        (should (equal (bv-list--relative-time timestamp now)
                       (cdr case)))))
    (should (equal (bv-list--relative-time "not-a-time" now) "unknown"))
    (should (equal (bv-list--relative-time nil now) "unknown"))))

(ert-deftest bv-list-responsive-row-preserves-leading-fields-and-age ()
  (with-temp-buffer
    (bv-list-mode)
    (let* ((columns
            (vector
             (propertize "✨" 'help-echo "Type: feature")
             (propertize "P1" 'face 'bv-priority-1-face)
             (propertize "DONE" 'face 'bv-status-closed-face)
             (propertize "bve-long-identifier" 'face 'bv-issue-id-face)
             "A title whose ending must disappear before the age does"
             (propertize "6m ago" 'face 'bv-muted-face)))
           (id "bve-long-identifier"))
      (cl-letf (((symbol-function 'bv-list--display-width) (lambda () 58)))
        (bv-list--print-entry id columns))
      (goto-char (point-min))
      (should (equal (tabulated-list-get-id) id))
      (should (string-match-p
               "✨ P1 DONE bve-long-identifier A title.*…"
               (buffer-string)))
      (should-not (string-match-p "age does" (buffer-string)))
      (search-forward "6m ago")
      (should (eq (get-text-property (1- (point)) 'face) 'bv-muted-face))
      (let* ((change (previous-single-property-change
                      (match-beginning 0) 'display nil
                      (line-beginning-position)))
             (alignment (and change
                             (get-text-property (1- change) 'display))))
        (should (equal alignment
                       '(space :align-to (- right-fringe 8))))))))

(ert-deftest bv-list-window-resize-rerenders-without-losing-selection ()
  (with-temp-buffer
    (bv-list-mode)
    (setq bv-list--displayed-width 80)
    (let ((buffer (current-buffer))
          (selected "bve-selected")
          printed restored)
      (let ((inhibit-read-only t))
        (insert "row\n")
        (put-text-property (point-min) (point-max)
                           'tabulated-list-id selected)
        (goto-char (point-min)))
      (cl-letf (((symbol-function 'window-buffer)
                 (lambda (_window) buffer))
                ((symbol-function 'window-body-width)
                 (lambda (_window) 120))
                ((symbol-function 'tabulated-list-print)
                 (lambda (&optional remember-position)
                   (setq printed remember-position)))
                ((symbol-function 'bv-list--restore-selection)
                 (lambda (id) (setq restored id))))
        (bv-list--window-size-change 'window)
        (should (= bv-list--displayed-width 120))
        (should printed)
        (should (equal restored selected))
        (setq printed nil)
        (bv-list--window-size-change 'window)
        (should-not printed)))))

(ert-deftest bv-list-age-prefers-created-time-and-explains-the-source ()
  (let* ((created "2026-08-12T01:00:00Z")
         (age (bv-list--age-string
               `(("created_at" . ,created)
                 ("updated_at" . "2026-08-12T01:59:00Z")))))
    (should (equal (get-text-property 0 'help-echo age)
                   (format "Created: %s" created)))))

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

(ert-deftest bv-list-open-watches-its-workspace ()
  (bv-test-with-workspace
    (let (buffer watched)
      (unwind-protect
          (cl-letf (((symbol-function 'bv-watch-workspace)
                     (lambda (function)
                       (setq watched (list (current-buffer) function))))
                    ((symbol-function 'bv-list-refresh) #'ignore)
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (setq buffer (bv-list--open 'all root))
            (should (equal watched (list buffer #'bv-list-refresh))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest bv-list-filter-keys-match-bv-and-existing-views ()
  (should (eq (lookup-key bv-list-mode-map (kbd "a")) #'bv-list-all))
  (should (eq (lookup-key bv-list-mode-map (kbd "o")) #'bv-list-open))
  (should (eq (lookup-key bv-list-mode-map (kbd "c")) #'bv-list-closed))
  (should (eq (lookup-key bv-list-mode-map (kbd "r")) #'bv-list-ready))
  (should (eq (lookup-key bv-list-mode-map (kbd "b")) #'bv-list-blocked))
  (should (eq (lookup-key bv-list-mode-map (kbd "l")) #'bv-list-label))
  (should (eq (lookup-key bv-list-mode-map (kbd "/")) #'bv-list-search))
  (should (eq (lookup-key bv-list-mode-map (kbd "RET")) #'bv-list-show)))

(ert-deftest bv-list-view-commands-switch-the-current-buffer-in-place ()
  (let ((buffer (generate-new-buffer " *bv in-place list*"))
        (refreshes 0))
    (unwind-protect
        (with-current-buffer buffer
          (bv-list-mode)
          (setq-local bv-workspace "/tmp/project/"
                      bv-list-kind 'all
                      bv-list-query "old")
          (cl-letf (((symbol-function 'bv-list-refresh)
                     (lambda () (cl-incf refreshes))))
            (should (eq (bv-list-ready) buffer))
            (should (eq (current-buffer) buffer))
            (should (eq bv-list-kind 'ready))
            (should-not bv-list-query)
            (should (= refreshes 1))
            (should (string-prefix-p "*Beads Ready: project*"
                                     (buffer-name)))
            (should (eq (bv-list-open) buffer))
            (should (eq bv-list-kind 'open))
            (should (= refreshes 2))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest bv-list-search-and-label-switch-in-place-with-query ()
  (let ((buffer (generate-new-buffer " *bv query list*")))
    (unwind-protect
        (with-current-buffer buffer
          (bv-list-mode)
          (setq-local bv-workspace "/tmp/project/")
          (cl-letf (((symbol-function 'bv-list-refresh) #'ignore))
            (should (eq (bv-list-search "quoted words") buffer))
            (should (eq bv-list-kind 'search))
            (should (equal bv-list-query "quoted words"))
            (should (eq (bv-list-label "frontend") buffer))
            (should (eq bv-list-kind 'label))
            (should (equal bv-list-query "frontend"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest bv-list-view-command-opens-a-buffer-outside-list-mode ()
  (with-temp-buffer
    (let (captured)
      (cl-letf (((symbol-function 'bv-list--open)
                 (lambda (kind directory query)
                   (setq captured (list kind directory query))
                   'opened)))
        (should (eq (bv-list-closed "/tmp/project/") 'opened))
        (should (equal captured '(closed "/tmp/project/" nil)))))))

(ert-deftest bv-list-known-labels-are-unique-and-sorted ()
  (let (captured)
    (cl-letf (((symbol-function 'bv-br-sync)
               (lambda (arguments workspace)
                 (setq captured (list arguments workspace))
                 (bv-test-json
                  "{\"issues\":[{\"labels\":[\"ui\",\"elisp\"]},{\"labels\":[\"ui\",\"tests\"]}]}"))))
      (should (equal (bv-list--known-labels "/tmp/project/")
                     '("elisp" "tests" "ui")))
      (should (equal captured
                     '(("list" "--all" "--json") "/tmp/project/"))))))

(provide 'bv-list-test)

;;; bv-list-test.el ends here
