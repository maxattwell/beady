;;; beady-test.el --- Tests for beady  -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests run on synthetic data.  Integration tests create a
;; temporary Beads database and are skipped when `bd' is not installed.
;; Evil tests are skipped when evil is not on the `load-path'.
;;
;; Run with: make test

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'beady)

;;;; Fixtures

(defun beady-test--issue (id &rest props)
  "Return an issue alist with ID and keyword PROPS."
  (cons (cons 'id id)
        (cl-loop for (key value) on props by #'cddr
                 collect (cons (intern (substring (symbol-name key) 1)) value))))

(defun beady-test--fixture ()
  "Return a list of synthetic issues."
  (list
   (beady-test--issue "a-1" :title "Auth overhaul" :status "open" :priority 1
                      :issue_type "epic" :labels '("backend")
                      :description "Rewrite the login system"
                      :created_at "2026-01-01T00:00:00Z" :updated_at "2026-01-05T00:00:00Z")
   (beady-test--issue "a-1.1" :title "OAuth flow" :status "in_progress" :priority 2
                      :issue_type "task" :assignee "alice" :parent "a-1"
                      :created_at "2026-01-02T00:00:00Z" :updated_at "2026-01-06T00:00:00Z")
   (beady-test--issue "a-1.2" :title "Token expiry bug" :status "open" :priority 0
                      :issue_type "bug" :parent "a-1"
                      :comment_count 3 :dependency_count 1
                      :created_at "2026-01-03T00:00:00Z" :updated_at "2026-01-04T00:00:00Z")
   (beady-test--issue "a-2" :title "Old chore" :status "closed" :priority 3
                      :issue_type "chore" :closed_at "2026-01-07T00:00:00Z"
                      :created_at "2025-12-01T00:00:00Z" :updated_at "2026-01-07T00:00:00Z")
   (beady-test--issue "a-3" :title "Dark mode" :status "deferred" :priority 4
                      :issue_type "feature" :labels '("frontend" "ui")
                      :created_at "2025-12-02T00:00:00Z" :updated_at "2026-01-01T00:00:00Z")
   (beady-test--issue "a-4" :title "Flaky test" :status "blocked" :priority 2
                      :issue_type "task" :assignee "bob" :labels '("backend")
                      :created_at "2025-12-03T00:00:00Z" :updated_at "2026-01-02T00:00:00Z")))

(defvar beady-test--blocked
  '(((id . "a-1.2") (blocked_by "a-1.1")))
  "Synthetic `bd blocked' output.")

(defmacro beady-test-with-list (&rest body)
  "Run BODY in a list buffer holding the synthetic fixture."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "beady-test" t)))
          (beady-list-show-hints nil))
     (puthash (cons root 'statuses) (copy-sequence beady--builtin-statuses)
              beady--metadata-cache)
     (unwind-protect
         (with-temp-buffer
           (beady-list-mode)
           (setq default-directory root
                 beady--root root)
           (beady-list--set-data (beady-test--fixture) beady-test--blocked)
           (beady-list--render)
           ,@body)
       (delete-directory root t))))

(defun beady-test--visible-ids ()
  "Return the IDs currently displayed, in order."
  beady-list--displayed)

(defun beady-test--line-of (id)
  "Return the text of the line showing ID."
  (save-excursion
    (goto-char (beady-list--find 'beady-id id))
    (buffer-substring-no-properties (line-beginning-position) (line-end-position))))

;;;; Core

(ert-deftest beady-test-parse-json-skips-noise ()
  (should (equal (beady--parse-json "warning: foo\n[{\"id\": \"x\", \"ok\": false}]")
                 '(((id . "x") (ok))))
          )
  (should (null (beady--parse-json "nothing here"))))

(ert-deftest beady-test-json-array-p ()
  (should (beady--json-array-p nil))
  (should (beady--json-array-p '(((id . "a")) ((id . "b")))))
  ;; A JSON object such as an error payload is not a list of issues.
  (should-not (beady--json-array-p '((error . "boom") (hint . "x"))))
  (should-not (beady--json-array-p "text")))

(ert-deftest beady-test-error-message ()
  (should (equal (beady--error-message "Error: invalid status \"x\"\nhint" "" 1)
                 "invalid status \"x\""))
  (should (equal (beady--error-message "" "{\"error\": \"no issues found\"}" 1)
                 "no issues found"))
  (should (equal (beady--error-message "" "" 3) "bd exited with status 3")))

(ert-deftest beady-test-format-age ()
  (let ((now (encode-time '(0 0 12 10 1 2026 nil nil t))))
    (should (equal (beady--format-age (time-subtract now 30) now) "now"))
    (should (equal (beady--format-age (time-subtract now 300) now) "5m"))
    (should (equal (beady--format-age (time-subtract now (* 3 3600)) now) "3h"))
    (should (equal (beady--format-age (time-subtract now (* 2 86400)) now) "2d"))
    (should (equal (beady--format-age (time-subtract now (* 21 86400)) now) "3w"))
    (should (equal (beady--format-age (time-add now (* 2 86400)) now) "in 2d"))))

(ert-deftest beady-test-time-parsing ()
  (should (beady--time "2026-10-10T02:09:26.737472779Z"))
  (should-not (beady--time "0001-01-01T00:00:00Z"))
  (should-not (beady--time ""))
  (should-not (beady--time nil)))

(ert-deftest beady-test-ordered-statuses-with-custom ()
  (let ((statuses (append beady--builtin-statuses
                          '(("in_review" . "wip") ("qa" . "wip") ("on_hold" . "frozen")))))
    (should (equal (beady--ordered-statuses statuses)
                   '("in_progress" "hooked" "in_review" "qa" "open" "blocked"
                     "deferred" "pinned" "on_hold" "closed")))))

(ert-deftest beady-test-status-done-p ()
  (let ((statuses (append beady--builtin-statuses '(("shipped" . "done")))))
    (should (beady--status-done-p "closed" statuses))
    (should (beady--status-done-p "shipped" statuses))
    (should-not (beady--status-done-p "open" statuses))))

(ert-deftest beady-test-find-root ()
  (let ((dir (file-name-as-directory (make-temp-file "beady-root" t))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".beads" dir))
          (write-region "{}" nil (expand-file-name ".beads/metadata.json" dir))
          (make-directory (expand-file-name "src/deep" dir) t)
          (should (equal (beady-find-root (expand-file-name "src/deep" dir))
                         (file-name-as-directory (file-truename dir)))))
      (delete-directory dir t))))

(ert-deftest beady-test-missing-executable ()
  (let ((beady-executable "beady-test-no-such-program"))
    (should-error (beady--run '("list")) :type 'beady-error)))

;;;; List: filters

(ert-deftest beady-test-default-filter-hides-closed ()
  (beady-test-with-list
    (should (equal (beady-test--visible-ids) '("a-1.2" "a-1" "a-1.1" "a-4" "a-3")))))

(ert-deftest beady-test-status-presets ()
  (beady-test-with-list
    (beady-list-filter-closed)
    (should (equal (beady-test--visible-ids) '("a-2")))
    (beady-list-filter-ready)
    (should (equal (beady-test--visible-ids) '("a-1")))
    (beady-list-filter-blocked)
    (should (equal (sort (copy-sequence (beady-test--visible-ids)) #'string<) '("a-1.2" "a-4")))
    (beady-list-filter-all)
    (should (= (length (beady-test--visible-ids)) 6))))

(ert-deftest beady-test-field-filters ()
  (beady-test-with-list
    (beady-list-filter-all)
    (beady-list-filter-statuses '("deferred" "closed"))
    (should (equal (sort (copy-sequence (beady-test--visible-ids)) #'string<) '("a-2" "a-3")))
    (beady-list-filter-all)
    (beady-list-filter-types '("task"))
    (should (equal (sort (copy-sequence (beady-test--visible-ids)) #'string<) '("a-1.1" "a-4")))
    (beady-list-filter-types nil)
    (beady-list-filter-priorities '(0 1))
    (should (equal (beady-test--visible-ids) '("a-1.2" "a-1")))
    (beady-list-filter-priorities nil)
    (beady-list-filter-labels '("ui" "backend"))
    (should (equal (sort (copy-sequence (beady-test--visible-ids)) #'string<) '("a-1" "a-3" "a-4")))
    (beady-list-filter-labels nil)
    (beady-list-filter-assignees '("alice" ""))
    (should (equal (sort (copy-sequence (beady-test--visible-ids)) #'string<)
                   '("a-1" "a-1.1" "a-1.2" "a-2" "a-3")))
    (beady-list-filter-assignees nil)
    (beady-list-filter-parent "a-1")
    (should (equal (beady-test--visible-ids) '("a-1.2" "a-1" "a-1.1")))
    (beady-list-reset-filters)
    (should (equal (plist-get beady-list--filter :status) 'open))
    (should-not (plist-get beady-list--filter :parent))))

(ert-deftest beady-test-search ()
  (beady-test-with-list
    (beady-list-search "login")
    ;; Matches the description of a-1.
    (should (equal (beady-test--visible-ids) '("a-1")))
    (beady-list-search "BUG token")
    (should (equal (beady-test--visible-ids) '("a-1.2")))
    (beady-list-search "alice")
    (should (equal (beady-test--visible-ids) '("a-1.1")))
    (beady-list-search "")
    (should-not (plist-get beady-list--filter :search))))

(ert-deftest beady-test-query-ids-filter ()
  (beady-test-with-list
    (setq beady-list--filter (plist-put beady-list--filter :query "x"))
    (setq beady-list--query-ids (let ((h (make-hash-table :test #'equal)))
                                  (puthash "a-4" t h)
                                  h))
    (beady-list--render)
    (should (equal (beady-test--visible-ids) '("a-4")))))

;;;; List: sorting, grouping, tree

(ert-deftest beady-test-sorting ()
  (beady-test-with-list
    (beady-list-filter-all)
    (beady-list-set-sort 'priority)
    ;; a-1.1 and a-4 share P2: the more recently updated comes first.
    (should (equal (beady-test--visible-ids) '("a-1.2" "a-1" "a-1.1" "a-4" "a-2" "a-3")))
    (beady-list-set-sort 'updated)
    (should (equal (car (beady-test--visible-ids)) "a-2"))
    (beady-list-toggle-sort-reverse)
    (should (equal (car (beady-test--visible-ids)) "a-3"))
    (beady-list-toggle-sort-reverse)
    (beady-list-set-sort 'closed)
    ;; Beads without a close date come last regardless of direction.
    (should (equal (car (beady-test--visible-ids)) "a-2"))
    (beady-list-toggle-sort-reverse)
    (should (equal (car (beady-test--visible-ids)) "a-2"))
    (beady-list-set-sort 'title)
    (beady-list-toggle-sort-reverse)
    (should (equal (car (beady-test--visible-ids)) "a-1"))))

(ert-deftest beady-test-group-by-status ()
  (beady-test-with-list
    (beady-list-filter-all)
    (beady-list-set-group 'status)
    (should (equal beady-list--group-keys '("in_progress" "open" "blocked" "deferred" "closed")))
    (should (string-match-p "▾ ◐ wip (1)" (buffer-string)))))

(ert-deftest beady-test-group-by-lane ()
  (beady-test-with-list
    (beady-list-filter-all)
    (beady-list-set-group 'lane)
    (should (equal beady-list--group-keys '(blocked ready in-progress deferred closed)))
    (goto-char (beady-list--find 'beady-group 'blocked))
    (should (string-match-p "Blocked (2)" (buffer-substring (point) (line-end-position))))))

(ert-deftest beady-test-group-by-label-repeats-beads ()
  (beady-test-with-list
    (beady-list-set-group 'label)
    (should (equal beady-list--group-keys '("backend" "frontend" "ui" "")))
    ;; a-3 has two labels and appears in both groups, but once in the order.
    (should (= (cl-count "a-3" (beady-test--visible-ids) :test #'equal) 1))
    (should (= (how-many "Dark mode" (point-min) (point-max)) 2))))

(ert-deftest beady-test-group-by-parent ()
  (beady-test-with-list
    (beady-list-set-group 'parent)
    (should (equal (car beady-list--group-keys) "a-1"))
    (goto-char (beady-list--find 'beady-group "a-1"))
    (should (string-match-p "a-1  Auth overhaul  0/2 closed (3)"
                            (buffer-substring-no-properties (point) (line-end-position))))
    ;; The epic heads its own group.
    (forward-line 1)
    (should (equal (beady-list--id-at-point) "a-1"))))

(ert-deftest beady-test-collapse-groups ()
  (beady-test-with-list
    (beady-list-set-group 'status)
    (goto-char (beady-list--find 'beady-group "open"))
    (beady-list-toggle-group)
    (should (member "open" beady-list--collapsed))
    (should-not (beady-list--find 'beady-id "a-1"))
    (should (string-match-p "▸ ○ open (2)" (buffer-string)))
    (beady-list-expand-all)
    (should (beady-list--find 'beady-id "a-1"))
    (beady-list-collapse-all)
    (should-not (beady-test--visible-ids))
    (beady-list-toggle-all-groups)
    (should (beady-test--visible-ids))))

(ert-deftest beady-test-tree ()
  (beady-test-with-list
    (beady-list-toggle-tree)
    (should (equal (beady-test--visible-ids) '("a-1" "a-1.2" "a-1.1" "a-4" "a-3")))
    (should (string-match-p "├─ Token expiry bug" (beady-test--line-of "a-1.2")))
    (should (string-match-p "└─ OAuth flow" (beady-test--line-of "a-1.1")))))

(ert-deftest beady-test-tree-rows-nested ()
  (let ((issues (list (beady-test--issue "r" :title "r")
                      (beady-test--issue "c1" :title "c1" :parent "r")
                      (beady-test--issue "g1" :title "g1" :parent "c1")
                      (beady-test--issue "c2" :title "c2" :parent "r"))))
    (should (equal (mapcar (lambda (row) (cons (beady--id (car row)) (cdr row)))
                           (beady-list--tree-rows issues))
                   '(("r" . "") ("c1" . "├─ ") ("g1" . "│  └─ ") ("c2" . "└─ "))))))

(ert-deftest beady-test-tree-rows-cycle ()
  (let ((issues (list (beady-test--issue "x" :parent "y")
                      (beady-test--issue "y" :parent "x"))))
    (should (= (length (beady-list--tree-rows issues)) 2))))

;;;; List: rendering, marks, navigation

(ert-deftest beady-test-render-row ()
  (beady-test-with-list
    (let ((line (beady-test--line-of "a-1.2")))
      (should (string-match-p "a-1\\.2 +P0 +⊘ open +Token expiry bug \\[3c\\] \\[dep:1\\]" line)))
    (should (string-match-p "#backend" (beady-test--line-of "a-4")))
    (should (string-match-p "@bob" (beady-test--line-of "a-4")))
    (should (string-match-p "\\`  ID +Pri Status +Title\\'"
                            beady-list--header))
    (should (string-match-p "5 of 6 beads" (buffer-string)))))

(ert-deftest beady-test-short-ids ()
  (beady-test-with-list
    (puthash (cons beady--root 'prefix) "a" beady--metadata-cache)
    (beady-list--render)
    (let ((line (beady-test--line-of "a-1.2")))
      (should (string-match-p "\\`  1\\.2 +P0 +⊘ open +Token expiry bug" line))
      (should-not (string-match-p "a-1\\.2" line)))
    (should (string-match-p "\\`  ID +Pri Status +Title\\'" beady-list--header))))

(ert-deftest beady-test-hidden-ids ()
  (beady-test-with-list
    (let ((beady-list-id-style 'hidden))
      (beady-list--render)
      (should (string-match-p "\\`  Pri +Status +Title\\'" beady-list--header))
      (should (string-match-p "\\`  P0 +⊘ open +Token expiry bug"
                              (beady-test--line-of "a-1.2"))))))

(ert-deftest beady-test-status-styles ()
  (beady-test-with-list
    (should (equal (beady--status-label "in_progress") "wip"))
    (should (equal (beady--status-label "closed") "closed"))
    (should (string-match-p "◐ wip" (beady-test--line-of "a-1.1")))
    (let ((beady-list-status-style 'icon))
      (beady-list--render)
      (let ((line (beady-test--line-of "a-1.1")))
        (should (string-match-p "◐" line))
        (should-not (string-match-p "wip" line))))
    (let ((beady-list-status-style 'full))
      (beady-list--render)
      (should (string-match-p "◐ in_progress" (beady-test--line-of "a-1.1"))))))

(ert-deftest beady-test-column-profile ()
  (beady-test-with-list
    (should (equal beady-list-columns beady-list--columns-compact))
    (beady-list-toggle-column-profile)
    (should (equal beady-list-columns beady-list--columns-wide))
    (should (string-match-p "ID +Pri Status +Type +Assignee Age Title"
                            beady-list--header))
    (beady-list-toggle-column-profile)
    (should (equal beady-list-columns beady-list--columns-compact))))

(ert-deftest beady-test-legend ()
  (beady-test-with-list
    (unwind-protect
        (progn
          (beady-list-show-legend)
          (let ((text (with-current-buffer
                          (get-buffer (format "*beady legend: %s*"
                                              (beady--project-name root)))
                        (buffer-substring-no-properties (point-min) (point-max)))))
            (should (string-match-p "in_progress" text))
            (should (string-match-p "wip" text))
            (should (string-match-p "bug" text))))
      (when-let* ((legend (get-buffer (format "*beady legend: %s*"
                                               (beady--project-name root)))))
        (kill-buffer legend)))))

(ert-deftest beady-test-blocked-marker ()
  (beady-test-with-list
    (let ((line (beady-test--line-of "a-1.2")))
      ;; The glyph replaces the status icon; the title keeps no marker.
      (should (string-match-p "⊘ open" line))
      (should-not (string-match-p "⊘ Token expiry bug" line)))
    (goto-char (beady-list--find 'beady-id "a-1.2"))
    (should (re-search-forward "⊘ open" (line-end-position) t))
    (should (eq (get-text-property (match-beginning 0) 'face)
                'beady-status-blocked))
    (should (string-match-p "Blocked by a-1.1"
                            (get-text-property (match-beginning 0) 'help-echo)))
    ;; A bead with the blocked status but no open dependency keeps its icon.
    (should (string-match-p "● blocked" (beady-test--line-of "a-4")))))

(ert-deftest beady-test-column-header ()
  (beady-test-with-list
    (should (string-match-p "ID +Pri Status +Title" (buffer-string)))
    (should (string-match-p "─" (buffer-string)))
    ;; With the body header on, the header line is not used.
    (should-not (beady-list--header-line))
    (let ((beady-list-show-column-header nil))
      (beady-list--render)
      (should (beady-list--header-line))
      (should-not (string-match-p "─" (buffer-string))))))

(ert-deftest beady-test-cell-formats ()
  (should (equal (substring-no-properties (beady--format-labels '("a" "b")))
                 "#a #b"))
  (should (equal (substring-no-properties (beady--format-assignee "alice"))
                 "@alice"))
  (should (equal (beady--format-assignee "") ""))
  (should (equal (beady--format-assignee nil) "")))

(ert-deftest beady-test-status-faces ()
  (should (eq (beady--status-face "pinned") 'beady-status-pinned))
  (should (eq (beady--status-face "hooked") 'beady-status-hooked))
  (should (eq (beady--status-face "blocked") 'beady-status-blocked))
  (should (eq (beady--status-face "custom") 'beady-status-other))
  (should (eq (beady--priority-face 0) 'beady-priority-0))
  ;; Closed titles and critical priorities carry B's extra emphasis.
  (should (eq (face-attribute 'beady-closed :strike-through nil t) t))
  (should (eq (face-attribute 'beady-priority-0 :inverse-video nil t) t)))

(ert-deftest beady-test-empty-filter-message ()
  (beady-test-with-list
    (beady-list-search "no such text anywhere")
    (should (string-match-p "No beads match the current filters" (buffer-string)))))

(ert-deftest beady-test-empty-project-message ()
  (beady-test-with-list
    (beady-list--set-data nil nil)
    (beady-list--render)
    (should (string-match-p "This project has no beads yet" (buffer-string)))
    ;; An error object instead of a list is treated as no data.
    (beady-list--set-data '((error . "boom")) '((error . "boom")))
    (beady-list--render)
    (should (string-match-p "no beads yet" (buffer-string)))))

(ert-deftest beady-test-group-missing-type ()
  (beady-test-with-list
    (beady-list--set-data (cons (beady-test--issue "z-1" :title "Typeless" :status "open"
                                                   :priority 2)
                                (beady-test--fixture))
                          beady-test--blocked)
    (beady-list-set-group 'type)
    (should (equal (car (last beady-list--group-keys)) ""))
    (goto-char (beady-list--find 'beady-group ""))
    (should (string-match-p "No type (1)" (buffer-substring (point) (line-end-position))))
    (beady-list-toggle-group)
    (should-not (beady-list--find 'beady-id "z-1"))))

(ert-deftest beady-test-marks-and-targets ()
  (beady-test-with-list
    (goto-char (beady-list--find 'beady-id "a-1"))
    (should (equal (beady-list--targets) '("a-1")))
    (beady-list-mark)
    (should (equal (beady-list--id-at-point) "a-1.1"))
    (beady-list-mark)
    (should (equal (beady-list--targets) '("a-1" "a-1.1")))
    (should (string-prefix-p "* a-1 " (beady-test--line-of "a-1")))
    (goto-char (beady-list--find 'beady-id "a-1.1"))
    (beady-list-unmark)
    (should (equal (beady-list--targets) '("a-1")))
    (beady-list-unmark-all)
    (should (equal (beady-list--targets) (list (beady-list--id-at-point))))))

(ert-deftest beady-test-end-of-buffer-is-a-bead ()
  (beady-test-with-list
    ;; Like evil's G: the last line must be a bead, not an empty line.
    (goto-char (point-max))
    (should (equal (beady-list--id-at-point) (car (last beady-list--displayed))))
    (should (equal (beady-list--targets) (last beady-list--displayed)))
    (beady-list-mark)
    (should-not (eq (char-before (point-max)) ?\n))
    (goto-char (point-max))
    (should (string-prefix-p "* " (buffer-substring (line-beginning-position)
                                                    (line-end-position))))))

(ert-deftest beady-test-region-targets ()
  (beady-test-with-list
    (transient-mark-mode 1)
    (goto-char (beady-list--find 'beady-id "a-1"))
    (push-mark (point) t t)
    (goto-char (beady-list--find 'beady-id "a-4"))
    ;; Region ends at the start of the a-4 line, which is excluded.
    (should (equal (beady-list--targets) '("a-1" "a-1.1")))
    (end-of-line)
    (should (equal (beady-list--targets) '("a-1" "a-1.1" "a-4")))
    (should (equal (beady--buffer-targets) '("a-1" "a-1.1" "a-4")))
    (should-not (region-active-p))))

(ert-deftest beady-test-navigation ()
  (beady-test-with-list
    (beady-list-set-group 'status)
    (goto-char (point-min))
    (beady-list-next)
    (should (equal (beady-list--id-at-point) "a-1.1"))
    (beady-list-next 2)
    (should (equal (beady-list--id-at-point) "a-1"))
    (beady-list-previous)
    (should (equal (beady-list--id-at-point) "a-1.2"))
    (beady-list-next-group)
    (should (equal (get-text-property (point) 'beady-group) "blocked"))
    (beady-list-previous-group)
    (should (equal (get-text-property (point) 'beady-group) "open"))
    (should-error (progn (goto-char (point-max)) (beady-list-next)) :type 'user-error)))

(ert-deftest beady-test-position-kept-across-render ()
  (beady-test-with-list
    (goto-char (beady-list--find 'beady-id "a-4"))
    (beady-list-set-sort 'title)
    (should (equal (beady-list--id-at-point) "a-4"))
    (beady-list-set-group 'type)
    (should (equal (beady-list--id-at-point) "a-4"))))

(ert-deftest beady-test-neighbor-id ()
  (beady-test-with-list
    (let ((buffer (current-buffer)))
      (should (equal (beady-list-neighbor-id buffer "a-1" 1) "a-1.1"))
      (should (equal (beady-list-neighbor-id buffer "a-1" -1) "a-1.2"))
      (should-not (beady-list-neighbor-id buffer "a-1.2" -1))
      (should-not (beady-list-neighbor-id buffer "a-3" 1)))))

(ert-deftest beady-test-lookup-and-known-issues ()
  (beady-test-with-list
    (should (equal (alist-get 'title (beady--lookup-issue "a-4")) "Flaky test"))
    (should (= (length (beady--known-issues)) 6))
    (should (equal (beady--known-values 'assignee) '("alice" "bob")))
    (should (equal (beady--known-values 'labels) '("backend" "frontend" "ui")))))

;;;; Menus and hints

(ert-deftest beady-test-hints-follow-keymap ()
  (beady-test-with-list
    (should (equal (beady--key-for 'beady-list-dispatch) "?"))
    (should (equal (beady--key-for 'beady-list-refresh) "g"))
    (should (string-match-p "s status" (beady--hints '((beady-status-menu . "status")))))))

(ert-deftest beady-test-view-menu-renders ()
  (beady-test-with-list
    (switch-to-buffer (current-buffer))
    (beady-list-set-sort 'updated)
    (beady-list-view-menu)
    (unwind-protect
        (let ((text (with-current-buffer (get-buffer " *transient*") (buffer-string))))
          (should (string-match-p "Sort by" text))
          (should (string-match-p "Group by" text))
          (should (string-match-p "Filter by" text))
          (should (string-match-p "5 of 6 beads shown" text))
          ;; The active sort field is highlighted.
          (with-current-buffer (get-buffer " *transient*")
            (goto-char (point-min))
            (search-forward "Last update")
            (let ((face (get-text-property (match-beginning 0) 'face)))
              (should (memq 'transient-value (ensure-list face))))
            (search-forward "Creation")
            (let ((face (get-text-property (match-beginning 0) 'face)))
              (should-not (memq 'transient-value (ensure-list face))))))
      (transient--emergency-exit))))

;;;; Show

(ert-deftest beady-test-show-render ()
  (let* ((root (file-name-as-directory (make-temp-file "beady-test" t)))
         (beady-show-fontify-markdown nil)
         (issue (beady-test--issue
                 "s-1" :title "Show me" :status "in_progress" :priority 1
                 :issue_type "epic" :assignee "alice" :labels '("x" "y")
                 :description "Some *markdown*" :notes "A note"
                 :created_at "2026-01-01T00:00:00Z" :updated_at "2026-01-02T00:00:00Z"
                 :epic_total_children 4 :epic_closed_children 1
                 :dependencies '(((id . "s-0") (title . "Blocker") (status . "open")
                                  (priority . 2) (dependency_type . "blocks")))
                 :dependents '(((id . "s-1.1") (title . "Child") (status . "closed")
                                (priority . 3) (dependency_type . "parent-child")))
                 :comments '(((author . "bob") (text . "Looks good")
                              (created_at . "2026-01-03T00:00:00Z"))))))
    (puthash (cons root 'statuses) (copy-sequence beady--builtin-statuses) beady--metadata-cache)
    (unwind-protect
        (with-temp-buffer
          (beady-show-mode)
          (setq beady--root root
                beady-show--id "s-1"
                beady-show--issue issue
                beady-show--complete t)
          (beady-show--render t)
          (let ((text (buffer-string)))
            (should (string-match-p "\\`◐ s-1  Show me" text))
            (should (string-match-p "Status +◐ in_progress  ⊘ blocked by s-0" text))
            (should (string-match-p "Assignee +@alice" text))
            (should (string-match-p "Labels +#x #y" text))
            (should (string-match-p "Progress .* 1 of 4 closed" text))
            (should (string-match-p "Description\nSome \\*markdown\\*" text))
            (should (string-match-p "Notes\nA note" text))
            (should (string-match-p "Depends on\n  → ○ s-0  P2  Blocker" text))
            (should (string-match-p "Children\n  ↓ ✓ s-1.1  P3  Child" text))
            (should (string-match-p "Comments (1)\n  bob" text))
            (should (string-match-p "Looks good" text)))
          ;; IDs are buttons that lead to the related bead.
          (goto-char (point-min))
          (forward-button 1)
          (should (equal (button-get (button-at (point)) 'beady-id) "s-1.1"))
          (forward-button 1)
          (should (equal (button-get (button-at (point)) 'beady-id) "s-0"))
          (goto-char (point-min))
          (beady-show-next-section)
          (should (looking-at "Description"))
          (beady-show-next-section)
          (should (looking-at "Notes"))
          (beady-show-previous-section)
          (should (looking-at "Description"))
          (should (equal (beady--buffer-targets) '("s-1"))))
      (delete-directory root t))))

(ert-deftest beady-test-show-markdown-faces ()
  (skip-unless (require 'markdown-mode nil t))
  (let ((beady-show-fontify-markdown t))
    (let ((text (beady-show--fontify "# Title\n\nSome **bold** text")))
      (should (equal (substring-no-properties text) "# Title\n\nSome **bold** text"))
      (should (get-text-property (string-search "bold" text) 'face text)))))

;;;; Integration with bd

(defvar beady-test--db nil "Directory of the integration test database.")

(defun beady-test--wait (predicate &optional timeout)
  "Wait until PREDICATE returns non-nil, at most TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 30))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(defun beady-test--wait-list (buffer)
  "Wait until list BUFFER has finished refreshing."
  (beady-test--wait (lambda () (with-current-buffer buffer
                                 (and beady-list--loaded (null beady-list--processes))))))

(defun beady-test--show (id)
  "Return the `bd show' data of ID."
  (car (beady--run-json (list "show" id))))

(defmacro beady-test-with-db (&rest body)
  "Run BODY in a fresh Beads database."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (file-truename (make-temp-file "beady-db" t))))
          (default-directory dir)
          (beady-list-show-hints nil)
          (beady-display-buffer-action '(display-buffer-same-window)))
     (unwind-protect
         (progn
           (call-process "git" nil nil nil "init" "-q")
           (beady--run '("init" "--non-interactive" "--prefix" "tst"
                         "--skip-agents" "--skip-hooks" "--quiet"))
           ,@body)
       (dolist (buffer (beady--buffers dir))
         (kill-buffer buffer))
       (beady--forget-metadata dir)
       (delete-directory dir t))))

(ert-deftest beady-test-integration ()
  (skip-unless (executable-find "bd"))
  (beady-test-with-db
    (let* ((epic (beady-create "Integration epic" '("--type=epic" "--priority=1")))
           (task (beady-create "Integration task" (list "--type=task" (concat "--parent=" epic))))
           (bug (beady-create "Integration bug" '("--type=bug" "--priority=0" "--labels=backend")))
           (list (beady-list dir)))
      (beady-test--wait-list list)
      (with-current-buffer list
        ;; The list shows the new beads, highest priority first.
        (should (equal (car beady-list--displayed) bug))
        (should (member task beady-list--displayed))
        ;; Status changes.
        (beady-set-status "in_progress" (list task))
        (beady-test--wait-list list)
        (should (equal (alist-get 'status (beady-test--show task)) "in_progress"))
        (should (equal (alist-get 'status (gethash task beady-list--table)) "in_progress"))
        (beady--close (list bug) "fixed it")
        (beady-test--wait-list list)
        (let ((data (beady-test--show bug)))
          (should (equal (alist-get 'status data) "closed"))
          (should (equal (alist-get 'close_reason data) "fixed it")))
        ;; Closed beads disappear from the default view.
        (should-not (member bug beady-list--displayed))
        ;; Opening a closed bead reopens it.
        (beady-status-open (list bug))
        (beady-test--wait-list list)
        (should (equal (alist-get 'status (beady-test--show bug)) "open"))
        ;; Deferring and opening again.
        (beady-defer (list bug) "")
        (should (equal (alist-get 'status (beady-test--show bug)) "deferred"))
        (beady-test--wait-list list)
        (beady-status-open (list bug))
        (should (equal (alist-get 'status (beady-test--show bug)) "open"))
        ;; Closing an epic with open children offers to force it.
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (beady--close (list epic) ""))
        (should (equal (alist-get 'status (beady-test--show epic)) "closed"))
        (beady-test--wait-list list)
        (beady-status-open (list epic))
        (should (equal (alist-get 'status (beady-test--show epic)) "open"))
        ;; Invalid statuses are reported.
        (should-error (beady-set-status "no-such-status" (list task)) :type 'beady-error)
        ;; Priority, assignee and labels on several beads at once.
        (beady-set-priority 3 (list task bug))
        (should (= (alist-get 'priority (beady-test--show task)) 3))
        (should (= (alist-get 'priority (beady-test--show bug)) 3))
        (beady-assign "carol" (list task))
        (should (equal (alist-get 'assignee (beady-test--show task)) "carol"))
        ;; bd refuses to take a claimed bead away from its holder; beady
        ;; offers to retry with --force.
        (let ((asked nil))
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (prompt) (setq asked prompt) t)))
            (beady-assign "" (list task)))
          (should (string-match-p "Retry with --force" asked)))
        (should-not (alist-get 'assignee (beady-test--show task)))
        (beady-add-labels '("ui" "urgent") (list task))
        (should (equal (sort (alist-get 'labels (beady-test--show task)) #'string<)
                       '("ui" "urgent")))
        (beady-remove-labels '("ui") (list task))
        (should (equal (alist-get 'labels (beady-test--show task)) '("urgent")))
        ;; Dependencies are reflected in the blocked state.
        (beady-add-blocker bug (list task))
        (beady-test--wait-list list)
        (should (beady-list--dep-blocked-p (gethash task beady-list--table)))
        (beady-remove-blocker bug task)
        (beady-test--wait-list list)
        (should-not (beady-list--dep-blocked-p (gethash task beady-list--table)))
        ;; Text fields through a compose buffer.
        (beady-edit-field task 'description)
        (with-current-buffer (get-buffer (format "*beady description: %s*" task))
          (insert "- starts with a dash\n\nSecond paragraph")
          (beady-compose-finish))
        (should (equal (alist-get 'description (beady-test--show task))
                       "- starts with a dash\n\nSecond paragraph"))
        (beady-add-comment (list task))
        (with-current-buffer (get-buffer (format "*beady comment: %s*" task))
          (insert "--looks like a flag but is a comment")
          (beady-compose-finish))
        (let ((comments (beady--run-json (list "comments" task))))
          (should (equal (alist-get 'text (car comments))
                         "--looks like a flag but is a comment")))
        (beady-edit-title task "Renamed task")
        (should (equal (alist-get 'title (beady-test--show task)) "Renamed task"))
        ;; bd query filtering.
        (beady-test--wait-list list)
        (beady-list-filter-query "type=bug")
        (beady-test--wait-list list)
        (should (equal beady-list--displayed (list bug)))
        (beady-list-filter-query "")
        (beady-test--wait-list list)
        ;; The bead view.
        (let ((show (beady-show-issue task dir)))
          (with-current-buffer show
            (beady-test--wait (lambda () (and beady-show--complete (null beady-show--process))))
            (let ((text (buffer-string)))
              (should (string-match-p "Renamed task" text))
              (should (string-match-p "Parent\n  ↑ ○ " text))
              (should (string-match-p "Comments (1)\n" text))
              (should (string-match-p "looks like a flag" text)))
            ;; Changes made from the bead view refresh it.
            (beady-set-priority 1 (beady--targets))
            (beady-test--wait (lambda () (and (null beady-show--process)
                                              (eql (alist-get 'priority beady-show--issue) 1))))
            ;; Following the parent link keeps a history.
            (beady-show-parent)
            (should (equal beady-show--id epic))
            (beady-show-back)
            (should (equal beady-show--id task))))))))

(ert-deftest beady-test-integration-errors ()
  (skip-unless (executable-find "bd"))
  (let ((dir (file-name-as-directory (make-temp-file "beady-nodb" t))))
    (unwind-protect
        (let ((default-directory dir))
          (should-error (beady--run-json '("list")) :type 'beady-error)
          (condition-case err
              (beady--run-json '("list"))
            (beady-error (should (string-match-p "no beads database" (cadr err))))))
      (delete-directory dir t))))

;;;; Evil

(ert-deftest beady-test-evil-bindings ()
  (skip-unless (require 'evil nil t))
  (require 'beady-evil)
  (beady-evil-setup)
  (beady-test-with-list
    (evil-local-mode 1)
    (evil-normal-state)
    (should (eq evil-state 'normal))
    (dolist (binding '(("RET" . beady-list-show)
                       ("s" . beady-status-menu)
                       ("x" . beady-close)
                       ("v" . beady-list-view-menu)
                       ("/" . beady-list-search)
                       ("?" . beady-list-dispatch)
                       ("gr" . beady-list-refresh)
                       ("za" . beady-list-toggle-group)
                       ("zM" . beady-list-collapse-all)
                       ("gj" . beady-list-next-group)
                       ("yy" . beady-copy-id)
                       ("q" . quit-window)))
      (should (eq (key-binding (kbd (car binding))) (cdr binding))))
    ;; Plain motions are still evil's.
    (should (eq (key-binding (kbd "j")) 'evil-next-line))
    ;; Hints reflect the evil bindings.
    (should (equal (beady--key-for 'beady-list-refresh) "g r"))
    (evil-visual-line)
    (should (eq (key-binding (kbd "s")) 'beady-status-menu))
    (should (eq (key-binding (kbd "m")) 'beady-list-mark))
    (evil-exit-visual-state)))

(ert-deftest beady-test-evil-visual-line-targets ()
  (skip-unless (require 'evil nil t))
  (require 'beady-evil)
  (beady-evil-setup)
  (beady-test-with-list
    (switch-to-buffer (current-buffer))
    (evil-local-mode 1)
    (evil-normal-state)
    (goto-char (beady-list--find 'beady-id "a-1"))
    (evil-visual-line)
    (forward-line 1)
    (evil-visual-refresh)
    ;; Line-wise selection covers both lines even with point at column 0.
    (should (equal (beady-list--targets) '("a-1" "a-1.1")))
    (beady-list-mark)
    (should (equal (beady-list--marked-ids) '("a-1" "a-1.1")))
    (should-not (evil-visual-state-p))))

(ert-deftest beady-test-evil-show-and-compose ()
  (skip-unless (require 'evil nil t))
  (require 'beady-evil)
  (beady-evil-setup)
  (with-temp-buffer
    (beady-show-mode)
    (evil-local-mode 1)
    (evil-normal-state)
    (dolist (binding '(("C-o" . beady-show-back)
                       (">" . beady-show-forward)
                       ("]]" . beady-show-next-section)
                       ("gr" . beady-show-refresh)
                       ("s" . beady-status-menu)
                       ("?" . beady-show-dispatch)))
      (should (eq (key-binding (kbd (car binding))) (cdr binding)))))
  (with-temp-buffer
    (text-mode)
    (evil-local-mode 1)
    (beady-compose-mode 1)
    (evil-normalize-keymaps)
    (evil-normal-state)
    (should (eq (key-binding (kbd "ZZ")) 'beady-compose-finish))
    (should (eq (key-binding (kbd "ZQ")) 'beady-compose-cancel))))

(ert-deftest beady-test-dispatch-plain-keys ()
  (beady-test-with-list
    (switch-to-buffer (current-buffer))
    (beady-list-dispatch)
    (unwind-protect
        (progn
          (should (eq (lookup-key transient--transient-map (kbd "o"))
                      'beady-list-show-other-window))
          (should (eq (lookup-key transient--transient-map (kbd "C-o"))
                      'beady-list-display))
          (should-not (eq (lookup-key transient--transient-map (kbd "go"))
                          'beady-list-show-other-window)))
      (transient--emergency-exit))))

(ert-deftest beady-test-dispatch-evil-keys ()
  (skip-unless (require 'evil nil t))
  (require 'beady-evil)
  (beady-evil-setup)
  (beady-test-with-list
    (switch-to-buffer (current-buffer))
    (evil-local-mode 1)
    (evil-normal-state)
    (beady-list-dispatch)
    (unwind-protect
        (progn
          (should (eq (lookup-key transient--transient-map (kbd "go"))
                      'beady-list-show-other-window))
          (should (eq (lookup-key transient--transient-map (kbd "gO"))
                      'beady-list-display))
          (should (eq (lookup-key transient--transient-map (kbd "gr"))
                      'beady-list-refresh))
          (should-not (lookup-key transient--transient-map (kbd "o"))))
      (transient--emergency-exit))))

(defun beady-test--evil-probe (body)
  "Run BODY in a batch Emacs with beady, evil and goto-chg loadable.
BODY is Elisp source.  Return the output of the child process."
  (let ((evil (locate-library "evil"))
        (goto-chg (locate-library "goto-chg"))
        (beady (locate-library "beady-core")))
    (unless (and evil goto-chg beady)
      (ert-skip "evil and goto-chg are needed for this test"))
    (let* ((emacs (or (and invocation-directory invocation-name
                           (expand-file-name invocation-name invocation-directory))
                      (executable-find "emacs")))
           (probe (make-temp-file "beady-evil-probe" nil ".el"))
           (out (generate-new-buffer " *beady-evil-probe*"))
           (dirs (delete-dups (mapcar #'file-name-directory
                                      (list evil goto-chg beady))))
           (status nil))
      (unwind-protect
          (progn
            (with-temp-file probe
              (insert ";; -*- lexical-binding: t; -*-\n" body))
            (setq status
                  (apply #'call-process emacs nil out nil
                         (append (list "-Q" "--batch")
                                 (cl-loop for dir in dirs append (list "-L" dir))
                                 (list "-l" probe))))
            (should (eql status 0))
            (with-current-buffer out (buffer-string)))
        (delete-file probe)
        (kill-buffer out)))))

(ert-deftest beady-test-evil-late-load ()
  "Evil bindings install into a buffer that existed before evil loaded."
  (let ((text (beady-test--evil-probe
               (concat
                "(require 'beady)\n"
                "(with-current-buffer (generate-new-buffer \"*beady-late*\")\n"
                "  (beady-list-mode)\n"
                "  (princ (format \"BEFORE s=%S gr=%S go=%S C-o=%S state=%S\\n\"\n"
                "                 (key-binding (kbd \"s\"))\n"
                "                 (key-binding (kbd \"gr\"))\n"
                "                 (key-binding (kbd \"go\"))\n"
                "                 (key-binding (kbd \"C-o\"))\n"
                "                 (and (fboundp 'evil-initial-state)\n"
                "                      (evil-initial-state 'beady-list-mode)))))\n"
                "(require 'evil)\n"
                "(with-current-buffer \"*beady-late*\"\n"
                "  (evil-local-mode 1)\n"
                "  (evil-normal-state)\n"
                "  (princ (format \"AFTER s=%S gr=%S go=%S C-o=%S state=%S\\n\"\n"
                "                 (key-binding (kbd \"s\"))\n"
                "                 (key-binding (kbd \"gr\"))\n"
                "                 (key-binding (kbd \"go\"))\n"
                "                 (key-binding (kbd \"C-o\")) evil-state)))\n"))))
    (should (string-match-p
             "BEFORE s=beady-status-menu gr=nil go=nil C-o=beady-list-display state=nil"
             text))
    (should (string-match-p
             "AFTER s=beady-status-menu gr=beady-list-refresh go=beady-list-show-other-window C-o=evil-jump-backward state=normal"
             text))))

(ert-deftest beady-test-evil-integration-off ()
  "With `beady-evil-integration' nil, evil bindings are never installed."
  (let ((text (beady-test--evil-probe
               (concat
                "(setq beady-evil-integration nil)\n"
                "(require 'beady)\n"
                "(require 'evil)\n"
                "(with-current-buffer (generate-new-buffer \"*beady-off*\")\n"
                "  (beady-list-mode)\n"
                "  (evil-local-mode 1)\n"
                "  (evil-normal-state)\n"
                "  (princ (format \"OFF s=%S gr=%S go=%S\\n\"\n"
                "                 (key-binding (kbd \"s\"))\n"
                "                 (key-binding (kbd \"gr\"))\n"
                "                 (key-binding (kbd \"go\")))))\n"))))
    (should (string-match-p "OFF s=evil-substitute gr=nil go=evil-goto-char" text))))

(provide 'beady-test)
;;; beady-test.el ends here
