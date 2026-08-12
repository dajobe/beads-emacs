;;; bv-triage-test.el --- Tests for bv-triage  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Dave Beckett
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'test-helper)
(require 'bv-triage)

(defconst bv-triage-test--brief-json
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

(defconst bv-triage-test--plan-json
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

(ert-deftest bv-triage-arguments-use-only-robot-json-flags ()
  (with-temp-buffer
    (bv-triage-mode)
    (setq bv-triage-kind 'triage)
    (should (equal (bv-triage--args)
                   '("--robot-triage" "--brief" "--format" "json")))
    (setq bv-triage-kind 'plan)
    (should (equal (bv-triage--args)
                   '("--robot-plan" "--format" "json")))
    (setq bv-triage-kind 'next)
    (should (equal (bv-triage--args)
                   '("--robot-next" "--format" "json")))
    (setq bv-triage-kind 'unsupported)
    (should-error (bv-triage--args))))

(ert-deftest bv-triage-renders-top-level-brief-envelope ()
  (with-temp-buffer
    (bv-triage-mode)
    (setq-local bv-workspace default-directory)
    (bv-triage-render 'triage (bv-test-json bv-triage-test--brief-json))
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
      (should (equal (button-get button 'bv-issue-id) "bve-top")))))

(ert-deftest bv-triage-renders-nested-plan-plan-tracks-envelope ()
  (with-temp-buffer
    (bv-triage-mode)
    (setq-local bv-workspace default-directory)
    (bv-triage-render 'plan (bv-test-json bv-triage-test--plan-json))
    (let ((text (buffer-string)))
      (dolist (fragment '("Beads execution plan" "Actionable:       2"
                          "Blocked:          1" "Track A" "Independent"
                          "bve-a  First" "P1" "[open]" "unblocks bve-b"
                          "Track B" "bve-c  Second" "Plan summary"
                          "Highest impact: bve-a" "Clears the critical path"))
        (should (string-match-p (regexp-quote fragment) text))))))

(ert-deftest bv-triage-next-renders-reasons-from-installed-response ()
  (with-temp-buffer
    (bv-triage-mode)
    (setq-local bv-workspace default-directory)
    (bv-triage-render
     'next
     (bv-test-json
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

(ert-deftest bv-triage-next-renders-recommendation-envelope ()
  (with-temp-buffer
    (bv-triage-mode)
    (setq-local bv-workspace default-directory)
    (bv-triage-render
     'next
     (bv-test-json
      "{\"recommendation\":{\"id\":\"bve-wrapped\",\"title\":\"Wrapped\",\"reason\":\"Top ranked\"}}"))
    (should (string-match-p "bve-wrapped  Wrapped" (buffer-string)))
    (should (string-match-p "Top ranked" (buffer-string)))))

(ert-deftest bv-triage-next-renders-no-actionable-and-degraded-details ()
  (with-temp-buffer
    (bv-triage-mode)
    (bv-triage-render
     'next
     (bv-test-json
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
    (bv-triage-mode)
    (bv-triage-render 'next (bv-test-json "{}"))
    (should (string-match-p
             "No actionable recommendation is available"
             (buffer-string)))))

(ert-deftest bv-triage-refresh-passes-exact-command-workspace-and-buffer ()
  (bv-test-with-workspace
    (with-temp-buffer
      (bv-triage-mode)
      (setq-local bv-workspace (file-name-as-directory (file-truename root)))
      (setq-local bv-triage-kind 'plan)
      (let (captured)
        (cl-letf (((symbol-function 'bv-bv-async)
                   (lambda (arguments callback _error workspace buffer)
                     (setq captured (list arguments workspace buffer))
                     (funcall callback
                              (bv-test-json bv-triage-test--plan-json)))))
          (bv-triage-refresh))
        (should (equal (car captured)
                       '("--robot-plan" "--format" "json")))
        (should (equal (cadr captured) bv-workspace))
        (should (eq (caddr captured) (current-buffer)))
        (should-not bv-triage--busy)
        (should (equal bv-triage-data
                       (bv-test-json bv-triage-test--plan-json)))))))

(ert-deftest bv-triage-failure-clears-busy-and-keeps-old-data ()
  (with-temp-buffer
    (bv-triage-mode)
    (setq-local bv-workspace default-directory)
    (setq-local bv-triage-kind 'triage)
    (setq bv-triage-data '(("old" . t)))
    (let (reported)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest arguments)
                   (setq reported (apply #'format format-string arguments))))
                ((symbol-function 'bv-bv-async)
                 (lambda (_arguments _callback error-callback
                          _workspace _buffer)
                   (funcall error-callback '(:stderr "analysis failed")))))
        (bv-triage-refresh))
      (should-not bv-triage--busy)
      (should (equal bv-triage-data '(("old" . t))))
      (should (string-match-p "Beads analysis failed" reported)))))

(ert-deftest bv-triage-button-opens-issue-in-buffer-workspace ()
  (with-temp-buffer
    (setq-local bv-workspace "/tmp/project/")
    (let (opened)
      (cl-letf (((symbol-function 'bv-show)
                 (lambda (id workspace) (setq opened (list id workspace))))
                ((symbol-function 'button-get)
                 (lambda (_button property)
                   (pcase property
                     ('bv-issue-id "bve-click")
                     ('bv-workspace "/tmp/project/")))))
        (bv-triage--issue-action 'button))
      (should (equal opened '("bve-click" "/tmp/project/"))))))

(ert-deftest bv-triage-errors-outside-mode-and-for-unknown-render-kind ()
  (with-temp-buffer
    (should-error (bv-triage-refresh) :type 'user-error)
    (should-error (bv-triage-render 'unknown nil))))

(provide 'bv-triage-test)

;;; bv-triage-test.el ends here
