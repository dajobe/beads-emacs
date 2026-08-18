;;; beads-list-test.el --- Tests for beads-list  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'test-helper)
(require 'beads-list)
(require 'beads-transient)

(ert-deftest beads-list-arguments-match-br-interface ()
  (with-temp-buffer
    (beads-list-mode)
    (dolist (case '((all . ("list" "--all" "--json"))
                    (open . ("list" "--status" "open" "--json"))
                    (closed . ("list" "--status" "closed" "--json"))
                    (ready . ("ready" "--json"))
                    (blocked . ("blocked" "--json"))))
      (setq beads-list-kind (car case))
      (should (equal (beads-list--args) (cdr case))))
    (setq beads-list-kind 'search
          beads-list-query "quoted words")
    (should (equal (beads-list--args)
                   '("search" "quoted words" "--json")))
    (setq beads-list-kind 'label
          beads-list-query "frontend")
    (should (equal (beads-list--args)
                   '("list" "--all" "--label" "frontend" "--json")))
    (setq beads-list-kind 'unknown)
    (should-error (beads-list--args))))

(ert-deftest beads-list-installs-list-object-envelope-and-renders-faces ()
  (with-temp-buffer
    (beads-list-mode)
    (setq beads-list-kind 'all
          beads-list--refresh-generation 3
          beads-list--busy t)
    (beads-list--success
     (current-buffer) 3
     (beads-test-json
      (concat
       "{\"issues\":["
       "{\"id\":\"bve-1\",\"title\":\"First\",\"priority\":0,"
       "\"status\":\"open\",\"issue_type\":\"task\","
       "\"assignee\":\"dave\"},"
       "{\"id\":\"bve-2\",\"title\":\"Second\",\"priority\":3,"
       "\"status\":\"closed\",\"issue_type\":\"bug\"}]}")))
    (should (= (length beads-list-issues) 2))
    (should-not beads-list--busy)
    (should (string-prefix-p "All — 2 issues    TYPE PRI STATUS ID TITLE"
                             (car header-line-format)))
    (goto-char (point-min))
    (search-forward "📋")
    (search-forward "P0")
    (should (eq (get-text-property (1- (point)) 'face)
                'beads-priority-0-face))
    (search-forward "OPEN")
    (should (eq (get-text-property (1- (point)) 'face)
                'beads-status-open-face))
    (search-forward "P3")
    (should (eq (get-text-property (1- (point)) 'face)
                'beads-priority-low-face))
    (search-forward "DONE")
    (should (eq (get-text-property (1- (point)) 'face)
                'beads-status-closed-face))))

(ert-deftest beads-list-ready-array-envelope-and-singular-header ()
  (with-temp-buffer
    (beads-list-mode)
    (setq beads-list-kind 'ready
          beads-list--refresh-generation 1)
    (beads-list--success
     (current-buffer) 1
     (beads-test-json
      "[{\"id\":\"bve-ready\",\"title\":\"Do it\",\"priority\":2,\"status\":\"in_progress\",\"issue_type\":\"task\"}]"))
    (should (string-prefix-p "Ready — 1 issue    TYPE PRI STATUS ID TITLE"
                             (car header-line-format)))
    (goto-char (point-min))
    (search-forward "PROG")
    (should (eq (get-text-property (1- (point)) 'face)
                'beads-status-progress-face))))

(ert-deftest beads-list-blocked-view-overrides-open-status-face ()
  (with-temp-buffer
    (beads-list-mode)
    (setq beads-list-kind 'blocked)
    (let ((status (beads-list--status-string
                   '(("status" . "open") ("blocked_by_count" . 0)))))
      (should (equal status "BLKD"))
      (should (eq (get-text-property 0 'face status)
                  'beads-status-blocked-face)))))

(ert-deftest beads-list-type-icons-explain-known-and-custom-types ()
  (dolist (case '(("bug" . "🐛")
                  ("feature" . "✨")
                  ("task" . "📋")
                  ("epic" . "🚀")
                  ("chore" . "🧹")
                  ("custom" . "•")))
    (let ((icon (beads-list--type-icon
                 `(("issue_type" . ,(car case))))))
      (should (equal icon (cdr case)))
      (should (equal (get-text-property 0 'help-echo icon)
                     (format "Type: %s" (car case)))))))

(ert-deftest beads-list-compact-status-labels-match-beads-vocabulary ()
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
    (let ((beads-list-kind 'all))
      (should (equal (beads-list--status-string
                      `(("status" . ,(car case))))
                     (cdr case))))))

(ert-deftest beads-list-relative-time-has-compact-stable-boundaries ()
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
        (should (equal (beads-list--relative-time timestamp now)
                       (cdr case)))))
    (should (equal (beads-list--relative-time "not-a-time" now) "unknown"))
    (should (equal (beads-list--relative-time nil now) "unknown"))))

(ert-deftest beads-list-responsive-row-preserves-leading-fields-and-age ()
  (with-temp-buffer
    (beads-list-mode)
    (let* ((columns
            (vector
             (propertize "✨" 'help-echo "Type: feature")
             (propertize "P1" 'face 'beads-priority-1-face)
             (propertize "DONE" 'face 'beads-status-closed-face)
             (propertize "bve-long-identifier" 'face 'beads-issue-id-face)
             "A title whose ending must disappear before the age does"
             (propertize "6m ago" 'face 'beads-muted-face)))
           (id "bve-long-identifier"))
      (cl-letf (((symbol-function 'beads-list--display-width) (lambda () 58)))
        (beads-list--print-entry id columns))
      (goto-char (point-min))
      (should (equal (tabulated-list-get-id) id))
      (should (string-match-p
               "✨ P1 DONE bve-long-identifier A title.*…"
               (buffer-string)))
      (should-not (string-match-p "age does" (buffer-string)))
      (search-forward "6m ago")
      (should (eq (get-text-property (1- (point)) 'face) 'beads-muted-face))
      (should-not (get-text-property (1- (point)) 'display)))))

(ert-deftest beads-list-responsive-row-keeps-age-visible-in-narrow-window ()
  (with-temp-buffer
    (beads-list-mode)
    (let ((columns
           (vector "✨" "P1" "DONE" "bve-long-identifier"
                   "A title that must be truncated" "5d ago")))
      (cl-letf (((symbol-function 'beads-list--display-width) (lambda () 40)))
        (beads-list--print-entry "bve-long-identifier" columns))
      (should (string-match-p "5d ago" (buffer-string)))
      (goto-char (point-min))
      (should (<= (string-width
                   (buffer-substring (line-beginning-position)
                                     (line-end-position)))
                  39)))))

(ert-deftest beads-list-window-resize-rerenders-without-losing-selection ()
  (with-temp-buffer
    (beads-list-mode)
    (setq beads-list--displayed-width 80)
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
                ((symbol-function 'beads-list--restore-selection)
                 (lambda (id) (setq restored id))))
        (beads-list--window-size-change 'window)
        (should (= beads-list--displayed-width 120))
        (should printed)
        (should (equal restored selected))
        (setq printed nil)
        (beads-list--window-size-change 'window)
        (should-not printed)))))

(ert-deftest beads-list-age-prefers-created-time-and-explains-the-source ()
  (let* ((created "2026-08-12T01:00:00Z")
         (age (beads-list--age-string
               `(("created_at" . ,created)
                 ("updated_at" . "2026-08-12T01:59:00Z")))))
    (should (equal (get-text-property 0 'help-echo age)
                   (format "Created: %s" created)))))

(ert-deftest beads-list-refresh-preserves-selection-and-uses-workspace ()
  (beads-test-with-workspace
   (with-temp-buffer
     (beads-list-mode)
     (setq-local beads-workspace (file-name-as-directory (file-truename root)))
     (setq beads-list-kind 'all
           beads-list-issues
           (beads-test-json
            "[{\"id\":\"bve-a\",\"title\":\"A\",\"priority\":1},{\"id\":\"bve-b\",\"title\":\"B\",\"priority\":2}]"))
     (tabulated-list-print)
     (goto-char (point-min))
     (forward-line 1)
     (should (equal (tabulated-list-get-id) "bve-b"))
     (let (captured)
       (cl-letf (((symbol-function 'beads-br-async)
                  (lambda (arguments callback _error workspace buffer)
                    (setq captured (list arguments workspace buffer))
                    (funcall callback
                             (beads-test-json
                              "{\"issues\":[{\"id\":\"bve-b\",\"title\":\"Changed\",\"priority\":2},{\"id\":\"bve-c\",\"title\":\"C\",\"priority\":3}]}")))))
         (beads-list-refresh))
       (should (equal (car captured) '("list" "--all" "--json")))
       (should (equal (cadr captured) beads-workspace))
       (should (eq (caddr captured) (current-buffer)))
       (should (equal (tabulated-list-get-id) "bve-b"))
       (should (= beads-list--refresh-generation 1))))))

(ert-deftest beads-list-stale-success-does-not-replace-newer-results ()
  (with-temp-buffer
    (beads-list-mode)
    (setq beads-list--refresh-generation 2
          beads-list-issues '((old . t))
          beads-list--busy t)
    (beads-list--success
     (current-buffer) 1
     (beads-test-json "{\"issues\":[{\"id\":\"stale\"}]}"))
    (should (equal beads-list-issues '((old . t))))
    (should beads-list--busy)))

(ert-deftest beads-list-failure-clears-busy-and-reports-error ()
  (with-temp-buffer
    (beads-list-mode)
    (setq beads-list--refresh-generation 4
          beads-list--busy t)
    (let (reported)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (setq reported (apply #'format format-string arguments)))))
        (beads-list--failure (current-buffer) 4 '(:stderr "bad flag")))
      (should-not beads-list--busy)
      (should (string-match-p "Beads refresh failed" reported))
      (should (string-match-p "bad flag" reported)))))

(ert-deftest beads-list-refresh-rejects-unrelated-buffer ()
  (with-temp-buffer
    (should-error (beads-list-refresh) :type 'user-error)))

(ert-deftest beads-list-open-watches-its-workspace ()
  (beads-test-with-workspace
   (let (buffer watched)
     (unwind-protect
         (cl-letf (((symbol-function 'beads-watch-workspace)
                    (lambda (function)
                      (setq watched (list (current-buffer) function))))
                   ((symbol-function 'beads-list-refresh) #'ignore)
                   ((symbol-function 'pop-to-buffer) #'ignore))
           (setq buffer (beads-list--open 'all root))
           (should (equal watched (list buffer #'beads-list-refresh))))
       (when (buffer-live-p buffer)
         (kill-buffer buffer))))))

(ert-deftest beads-list-filter-keys-match-beads-and-existing-views ()
  (should (eq (lookup-key beads-list-mode-map (kbd "a")) #'beads-list-all))
  (should (eq (lookup-key beads-list-mode-map (kbd "o")) #'beads-list-open))
  (should (eq (lookup-key beads-list-mode-map (kbd "O")) #'beads-list-open))
  (should (eq (lookup-key beads-list-mode-map (kbd "X")) #'beads-list-closed))
  (should (eq (lookup-key beads-list-mode-map (kbd "r")) #'beads-list-ready))
  (should (eq (lookup-key beads-list-mode-map (kbd "b")) #'beads-list-blocked))
  (should (eq (lookup-key beads-list-mode-map (kbd "l")) #'beads-list-label))
  (should (eq (lookup-key beads-list-mode-map (kbd "/")) #'beads-list-search))
  (should (eq (lookup-key beads-list-mode-map (kbd "c")) #'beads-create))
  (should (eq (lookup-key beads-list-mode-map (kbd "RET")) #'beads-list-show)))

(ert-deftest beads-list-direct-bindings-are-documented-in-command-menu ()
  (dolist (binding '(("RET" . beads-list-show)
                     ("g" . beads-list-refresh)
                     ("a" . beads-list-all)
                     ("o" . beads-list-open)
                     ("O" . beads-list-open)
                     ("X" . beads-list-closed)
                     ("r" . beads-list-ready)
                     ("b" . beads-list-blocked)
                     ("l" . beads-list-label)
                     ("/" . beads-list-search)
                     ("c" . beads-create)
                     ("C" . beads-claim)
                     ("e" . beads-update)
                     ("x" . beads-close)
                     ("R" . beads-reopen)))
    (should (eq (plist-get
                 (nth 2 (transient-get-suffix 'beads-list-menu (car binding)))
                 :command)
                (cdr binding)))))

(ert-deftest beads-list-view-commands-switch-the-current-buffer-in-place ()
  (let ((buffer (generate-new-buffer " *bv in-place list*"))
        (refreshes 0))
    (unwind-protect
        (with-current-buffer buffer
          (beads-list-mode)
          (setq-local beads-workspace "/tmp/project/"
                      beads-list-kind 'all
                      beads-list-query "old")
          (cl-letf (((symbol-function 'beads-list-refresh)
                     (lambda () (cl-incf refreshes))))
            (should (eq (beads-list-ready) buffer))
            (should (eq (current-buffer) buffer))
            (should (eq beads-list-kind 'ready))
            (should-not beads-list-query)
            (should (= refreshes 1))
            (should (string-prefix-p "*Beads Ready: project*"
                                     (buffer-name)))
            (should (eq (beads-list-open) buffer))
            (should (eq beads-list-kind 'open))
            (should (= refreshes 2))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest beads-list-search-and-label-switch-in-place-with-query ()
  (let ((buffer (generate-new-buffer " *bv query list*")))
    (unwind-protect
        (with-current-buffer buffer
          (beads-list-mode)
          (setq-local beads-workspace "/tmp/project/")
          (cl-letf (((symbol-function 'beads-list-refresh) #'ignore))
            (should (eq (beads-list-search "quoted words") buffer))
            (should (eq beads-list-kind 'search))
            (should (equal beads-list-query "quoted words"))
            (should (eq (beads-list-label "frontend") buffer))
            (should (eq beads-list-kind 'label))
            (should (equal beads-list-query "frontend"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest beads-list-view-command-opens-a-buffer-outside-list-mode ()
  (with-temp-buffer
    (let (captured)
      (cl-letf (((symbol-function 'beads-list--open)
                 (lambda (kind directory query)
                   (setq captured (list kind directory query))
                   'opened)))
        (should (eq (beads-list-closed "/tmp/project/") 'opened))
        (should (equal captured '(closed "/tmp/project/" nil)))))))

(ert-deftest beads-list-known-labels-are-unique-and-sorted ()
  (let (captured)
    (cl-letf (((symbol-function 'beads-br-sync)
               (lambda (arguments workspace)
                 (setq captured (list arguments workspace))
                 (beads-test-json
                  "{\"issues\":[{\"labels\":[\"ui\",\"elisp\"]},{\"labels\":[\"ui\",\"tests\"]}]}"))))
      (should (equal (beads-list--known-labels "/tmp/project/")
                     '("elisp" "tests" "ui")))
      (should (equal captured
                     '(("list" "--all" "--json") "/tmp/project/"))))))

(provide 'beads-list-test)

;;; beads-list-test.el ends here
