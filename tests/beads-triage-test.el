;;; beads-triage-test.el --- Tests for beads-triage  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'test-helper)
(require 'beads-triage)
(require 'beads-transient)

(ert-deftest beads-triage-direct-bindings-are-documented-in-command-menu ()
  (dolist (binding '(("g" . beads-triage-refresh)
                     ("t" . beads-triage)
                     ("p" . beads-plan)
                     ("o" . beads-next)
                     ("n" . forward-button)
                     ("N" . backward-button)
                     ("RET" . push-button)))
    (should (eq (plist-get
                 (nth 2 (transient-get-suffix 'beads-triage-menu (car binding)))
                 :command)
                (cdr binding)))))

(defconst beads-triage-test--brief-json
  (concat
   "{\"quick_ref\":{\"open_count\":4,\"actionable_count\":2,"
   "\"blocked_count\":2,\"top_picks\":[{\"id\":\"bve-top\","
   "\"title\":\"Top work\",\"status\":\"open\"}]},"
   "\"recommendations\":[{\"id\":\"bve-rec\","
   "\"title\":\"Recommended\",\"score\":0.875,"
   "\"reason\":\"Unblocks useful work\",\"unblocks\":[\"bve-child\"]}],"
   "\"quick_wins\":[{\"id\":\"bve-win\",\"title\":\"Quick win\"}],"
   "\"blockers_to_clear\":[{\"id\":\"bve-block\","
   "\"title\":\"Clear blocker\",\"blocked_by\":[\"bve-root\"]}]}" )
  "Representative top-level response from brief robot triage.")

(defconst beads-triage-test--plan-json
  (concat
   "{\"plan\":{\"total_actionable\":2,\"total_blocked\":1,"
   "\"tracks\":[{\"track_id\":\"Track A\",\"reason\":\"Independent\","
   "\"items\":[{\"id\":\"bve-a\",\"title\":\"First\","
   "\"priority\":1,\"status\":\"open\",\"unblocks\":[\"bve-b\"]}]},"
   "{\"track_id\":\"Track B\",\"items\":[{\"id\":\"bve-c\","
   "\"title\":\"Second\",\"priority\":2}]}],"
   "\"summary\":{\"highest_impact\":\"bve-a\","
   "\"impact_reason\":\"Clears the critical path\"}}}" )
  "Representative nested `plan.plan.tracks' response.")

(ert-deftest beads-triage-arguments-use-only-robot-json-flags ()
  (with-temp-buffer
    (beads-triage-mode)
    (setq beads-triage-kind 'triage)
    (should (equal (beads-triage--args)
                   '("--robot-triage" "--brief" "--format" "json")))
    (setq beads-triage-kind 'plan)
    (should (equal (beads-triage--args)
                   '("--robot-plan" "--format" "json")))
    (setq beads-triage-kind 'next)
    (should (equal (beads-triage--args)
                   '("--robot-next" "--format" "json")))
    (setq beads-triage-kind 'unsupported)
    (should-error (beads-triage--args))))

(ert-deftest beads-triage-renders-top-level-brief-envelope ()
  (with-temp-buffer
    (beads-triage-mode)
    (setq-local beads-workspace default-directory)
    (beads-triage-render 'triage (beads-test-json beads-triage-test--brief-json))
    (let ((text (buffer-string)))
      (dolist (fragment '("Beads triage" "Overview" "Open:             4"
                          "Actionable:       2" "Blocked:          2"
                          "Top picks" "bve-top  Top work" "Recommendations"
                          "bve-rec  Recommended" "score 0.875"
                          "Unblocks useful work" "unblocks bve-child"
                          "Quick wins" "bve-win  Quick win"
                          "Blockers to clear" "blocked by bve-root"))
        (should (string-match-p (regexp-quote fragment) text))))
    (goto-char (point-min))
    (search-forward "bve-top")
    (let ((button (button-at (1- (point)))))
      (should button)
      (should (equal (button-get button 'beads-issue-id) "bve-top")))))

(ert-deftest beads-triage-renders-nested-plan-plan-tracks-envelope ()
  (with-temp-buffer
    (beads-triage-mode)
    (setq-local beads-workspace default-directory)
    (beads-triage-render 'plan (beads-test-json beads-triage-test--plan-json))
    (let ((text (buffer-string)))
      (dolist (fragment '("Beads execution plan" "Actionable:       2"
                          "Blocked:          1" "Track A" "Independent"
                          "bve-a  First" "P1" "[open]" "unblocks bve-b"
                          "Track B" "bve-c  Second" "Plan summary"
                          "Highest impact: bve-a" "Clears the critical path"))
        (should (string-match-p (regexp-quote fragment) text))))))

(ert-deftest beads-triage-next-renders-reasons-from-installed-response ()
  (with-temp-buffer
    (beads-triage-mode)
    (setq-local beads-workspace default-directory)
    (beads-triage-render
     'next
     (beads-test-json
      (concat
       "{\"id\":\"bve-next\",\"title\":\"Next work\",\"score\":0.9,"
       "\"reasons\":[\"Ready and high impact\","
       "{\"reason\":\"Unblocks two issues\"},"
       "{\"message\":\"Fits the active scope\"}]}")))
    (let ((text (buffer-string)))
      (dolist (fragment '("Next Beads recommendation" "Recommended issue"
                          "bve-next  Next work" "score 0.900"
                          "Ready and high impact" "Unblocks two issues"
                          "Fits the active scope"))
        (should (string-match-p (regexp-quote fragment) text))))))

(ert-deftest beads-triage-next-renders-recommendation-envelope ()
  (with-temp-buffer
    (beads-triage-mode)
    (setq-local beads-workspace default-directory)
    (beads-triage-render
     'next
     (beads-test-json
      "{\"recommendation\":{\"id\":\"bve-wrapped\",\"title\":\"Wrapped\",\"reason\":\"Top ranked\"}}"))
    (should (string-match-p "bve-wrapped  Wrapped" (buffer-string)))
    (should (string-match-p "Top ranked" (buffer-string)))))

(ert-deftest beads-triage-next-renders-no-actionable-and-degraded-details ()
  (with-temp-buffer
    (beads-triage-mode)
    (beads-triage-render
     'next
     (beads-test-json
      (concat
       "{\"message\":\"No actionable issues\",\"degraded\":["
       "{\"message\":\"Graph data is incomplete\","
       "\"repair\":\"Run br sync --flush-only\"}]}")))
    (let ((text (buffer-string)))
      (should (string-match-p "No actionable issues" text))
      (should (string-match-p "Why" text))
      (should (string-match-p "Graph data is incomplete" text))
      (should (string-match-p "Run br sync --flush-only" text))))
  (with-temp-buffer
    (beads-triage-mode)
    (beads-triage-render 'next (beads-test-json "{}"))
    (should (string-match-p
             "No actionable recommendation is available"
             (buffer-string)))))

(ert-deftest beads-triage-refresh-passes-exact-command-workspace-and-buffer ()
  (beads-test-with-workspace
   (with-temp-buffer
     (beads-triage-mode)
     (setq-local beads-workspace (file-name-as-directory (file-truename root)))
     (setq-local beads-triage-kind 'plan)
     (let (captured)
       (cl-letf (((symbol-function 'beads-bv-async)
                  (lambda (arguments callback _error workspace buffer)
                    (setq captured (list arguments workspace buffer))
                    (funcall callback
                             (beads-test-json beads-triage-test--plan-json)))))
         (beads-triage-refresh))
       (should (equal (car captured)
                      '("--robot-plan" "--format" "json")))
       (should (equal (cadr captured) beads-workspace))
       (should (eq (caddr captured) (current-buffer)))
       (should-not beads-triage--busy)
       (should (equal beads-triage-data
                      (beads-test-json beads-triage-test--plan-json)))))))

(ert-deftest beads-triage-failure-clears-busy-and-keeps-old-data ()
  (with-temp-buffer
    (beads-triage-mode)
    (setq-local beads-workspace default-directory)
    (setq-local beads-triage-kind 'triage)
    (setq beads-triage-data '(("old" . t)))
    (let (reported)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (setq reported (apply #'format format-string arguments))))
                ((symbol-function 'beads-bv-async)
                 (lambda (_arguments _callback error-callback
                                     _workspace _buffer)
                   (funcall error-callback '(:stderr "analysis failed")))))
        (beads-triage-refresh))
      (should-not beads-triage--busy)
      (should (equal beads-triage-data '(("old" . t))))
      (should (string-match-p "Beads analysis failed" reported)))))

(ert-deftest beads-triage-button-opens-issue-in-buffer-workspace ()
  (with-temp-buffer
    (setq-local beads-workspace "/tmp/project/")
    (let (opened)
      (cl-letf (((symbol-function 'beads-show)
                 (lambda (id workspace) (setq opened (list id workspace))))
                ((symbol-function 'button-get)
                 (lambda (_button property)
                   (pcase property
                     ('beads-issue-id "bve-click")
                     ('beads-workspace "/tmp/project/")))))
        (beads-triage--issue-action 'button))
      (should (equal opened '("bve-click" "/tmp/project/"))))))

(ert-deftest beads-triage-errors-outside-mode-and-for-unknown-render-kind ()
  (with-temp-buffer
    (should-error (beads-triage-refresh) :type 'user-error)
    (should-error (beads-triage-render 'unknown nil))))

(ert-deftest beads-triage-open-watches-its-workspace ()
  (beads-test-with-workspace
   (let (buffer watched)
     (unwind-protect
         (cl-letf (((symbol-function 'beads-watch-workspace)
                    (lambda (function)
                      (setq watched (list (current-buffer) function))))
                   ((symbol-function 'beads-triage-refresh) #'ignore)
                   ((symbol-function 'pop-to-buffer) #'ignore))
           (setq buffer (beads-triage--open 'triage root))
           (should (equal watched (list buffer #'beads-triage-refresh))))
       (when (buffer-live-p buffer)
         (kill-buffer buffer))))))

(provide 'beads-triage-test)

;;; beads-triage-test.el ends here
