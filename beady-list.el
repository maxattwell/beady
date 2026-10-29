;;; beady-list.el --- List of beads  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Max Attwell <max.attwell@hotmail.com>
;; Assisted-by: pi:claude-opus-5.5

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `beady-list-mode' shows the beads of a project in a read-only
;; buffer.  All issues are loaded once per refresh (asynchronously, with
;; `bd list', `bd blocked' and `bd statuses' running in parallel);
;; filtering, live search, sorting, grouping and the hierarchical tree
;; view are then computed locally, so changing the view is instant.
;;
;; `beady-list-view-menu' is a transient that shows every view option
;; with its current value, and `beady-list-dispatch' lists every command.

;;; Code:

(require 'beady-core)
(require 'beady-actions)
(require 'beady-show)
(require 'hl-line)
(require 'text-property-search)
(require 'transient)

;;;; Options

(defcustom beady-list-default-filter '(:status open)
  "Filter applied to new list buffers.
A plist that may contain:
  :status      a preset (`open', `ready', `blocked', `closed', `all')
               or a list of status names
  :types       list of issue types
  :priorities  list of priorities (0-4)
  :labels      list of labels; beads with any of them match
  :assignees   list of assignees; \"\" matches unassigned beads
  :parent      ID of a bead whose descendants are shown
  :search      text that must appear in the bead (see
               `beady-list-search-fields')
  :query       an expression for `bd query'"
  :type 'plist
  :group 'beady)

(defcustom beady-list-default-sort 'priority
  "Field the list is sorted by in new list buffers."
  :type '(choice (const priority) (const updated) (const created)
                 (const closed) (const due) (const id) (const title)
                 (const status) (const type) (const assignee))
  :group 'beady)

(defcustom beady-list-default-sort-reverse nil
  "When non-nil, new list buffers use the reverse sort order."
  :type 'boolean
  :group 'beady)

(defcustom beady-list-default-group nil
  "How new list buffers are grouped."
  :type '(choice (const :tag "No grouping" nil) (const status)
                 (const :tag "Board lanes" lane) (const priority)
                 (const type) (const assignee) (const label)
                 (const :tag "Epic / parent" parent))
  :group 'beady)

(defcustom beady-list-default-tree nil
  "When non-nil, new list buffers show children under their parents."
  :type 'boolean
  :group 'beady)

(defconst beady-list--columns-wide
  '(mark id priority status type assignee age title labels)
  "Columns of the wide table layout.")

(defconst beady-list--columns-compact
  '(mark id priority status title type assignee age labels)
  "Columns of the compact table layout.
Columns after `title' are trailing: they are not padded and empty
ones are omitted.")

(defcustom beady-list-columns beady-list--columns-compact
  "Columns displayed in the list, in order.
Available columns are `mark', `id', `priority', `status', `type',
`assignee', `age', `title' and `labels'.  Columns after `title' form
an unpadded trailer whose empty columns are omitted.
`beady-list-toggle-column-profile' switches between the compact
default and the wide layout."
  :type '(repeat (choice (const mark) (const id) (const priority)
                         (const status) (const type) (const assignee)
                         (const age) (const title) (const labels)))
  :group 'beady)

(defcustom beady-list-id-style 'short
  "How bead IDs are displayed in the list.
`full' shows the whole ID, `short' strips the project prefix (for
example \"demo-egi.1\" becomes \"egi.1\") and `hidden' omits the ID
column entirely."
  :type '(choice (const full) (const short) (const hidden))
  :group 'beady)

(defcustom beady-list-status-style 'short
  "How statuses are displayed in the list.
`full' shows the whole status name, `short' uses the labels in
`beady-status-abbreviations' and `icon' shows only the status icon."
  :type '(choice (const full) (const short) (const icon))
  :group 'beady)

(defcustom beady-list-column-max-widths
  '((id . 24) (status . 14) (type . 10) (assignee . 16) (age . 5))
  "Maximum widths of the list columns that size themselves to the data."
  :type '(alist :key-type symbol :value-type integer)
  :group 'beady)

(defcustom beady-list-title-width nil
  "Width of the title column, or nil to not pad titles."
  :type '(choice (const :tag "Natural width" nil) integer)
  :group 'beady)

(defcustom beady-list-age-field 'updated_at
  "Timestamp shown in the age column."
  :type '(choice (const :tag "Last update" updated_at)
                 (const :tag "Creation" created_at))
  :group 'beady)

(defcustom beady-list-search-fields '(id title description labels assignee)
  "Fields that `beady-list-search' looks at."
  :type '(set (const id) (const title) (const description) (const design)
              (const acceptance_criteria) (const notes) (const labels)
              (const assignee) (const issue_type) (const status))
  :group 'beady)

(defcustom beady-list-search-delay 0.15
  "Seconds of idle time before the list follows the search being typed."
  :type 'number
  :group 'beady)

(defcustom beady-list-show-summary t
  "When non-nil, show a summary of the view at the top of the list."
  :type 'boolean
  :group 'beady)

(defcustom beady-list-show-hints t
  "When non-nil, show key hints under the summary."
  :type 'boolean
  :group 'beady)

(defcustom beady-list-show-column-header t
  "When non-nil, show the aligned table header in the list buffer.
When nil, the column titles are shown in the header line instead."
  :type 'boolean
  :group 'beady)

(defcustom beady-list-highlight-current-line t
  "When non-nil, highlight the current line in list buffers."
  :type 'boolean
  :group 'beady)

(defcustom beady-list-auto-refresh-interval nil
  "When a number, refresh visible list buffers every that many seconds."
  :type '(choice (const :tag "Never" nil) number)
  :group 'beady)

(defcustom beady-list-mode-hook nil
  "Hook run when entering `beady-list-mode'."
  :type 'hook
  :group 'beady)

;;;; State

(defvar-local beady-list--issues nil "All issues of the project.")
(defvar-local beady-list--loaded nil "Non-nil once issues have been loaded.")
(defvar-local beady-list--error nil "Error message of the last refresh.")
(defvar-local beady-list--processes nil "Processes of the running refresh.")
(defvar-local beady-list--table nil "Hash table mapping IDs to issues.")
(defvar-local beady-list--children nil "Hash table mapping IDs to child IDs.")
(defvar-local beady-list--blocked nil
  "Hash table mapping IDs of dependency-blocked beads to their blockers.")
(defvar-local beady-list--statuses nil "Alist of (STATUS . CATEGORY).")
(defvar-local beady-list--haystacks nil "Cache of search texts per ID.")
(defvar-local beady-list--query-ids nil "IDs matching the `bd query' filter.")
(defvar-local beady-list--query-error nil "Error of the `bd query' filter.")
(defvar-local beady-list--filter nil "Current filter plist.")
(defvar-local beady-list--sort nil "Current sort field.")
(defvar-local beady-list--sort-reverse nil "Non-nil to reverse the sort order.")
(defvar-local beady-list--group nil "Current grouping.")
(defvar-local beady-list--tree nil "Non-nil to show children under parents.")
(defvar-local beady-list--collapsed nil "Keys of collapsed groups.")
(defvar-local beady-list--group-keys nil "Keys of the groups displayed.")
(defvar-local beady-list--marks nil "Hash table of marked IDs.")
(defvar-local beady-list--displayed nil "IDs in display order.")
(defvar-local beady-list--widths nil "Alist of column widths.")
(defvar-local beady-list--header nil "Column header text.")
(defvar-local beady-list--now nil "Time used for ages while rendering.")
(defvar-local beady-list--row-cache nil
  "Hash table mapping IDs to alists of (PREFIX . ROW-STRING).")
(defvar-local beady-list--row-cache-key nil
  "Time and columns the row cache and column widths were computed for.")
(defvar-local beady-list--focus nil "ID to move to after the next render.")
(defvar-local beady-list--initialized nil "Non-nil after the first data render.")

(defconst beady-list--lanes
  '((blocked . "Blocked") (ready . "Ready") (in-progress . "In progress")
    (open . "Open, not ready") (deferred . "Deferred") (closed . "Closed"))
  "Board lanes in display order.")

(defconst beady-list--column-titles
  '((mark . " ") (id . "ID") (priority . "Pri") (status . "Status")
    (type . "Type") (assignee . "Assignee") (age . "Age") (title . "Title")
    (labels . "Labels"))
  "Header titles of the list columns.")

(defun beady-list--ensure ()
  "Signal an error unless the current buffer is a beads list."
  (unless (derived-mode-p 'beady-list-mode)
    (user-error "Not in a beads list buffer")))

;;;; Loading

(defun beady-list--cancel ()
  "Cancel the running refresh of the current buffer."
  (mapc #'beady--cancel-process beady-list--processes)
  (setq beady-list--processes nil))

(defun beady-list-refresh (&rest _)
  "Reload the beads of the current list buffer.
The display keeps its filters, sorting, grouping and marks."
  (interactive)
  (beady-list--ensure)
  (beady-list--cancel)
  (let* ((buffer (current-buffer))
         (query (plist-get beady-list--filter :query))
         (jobs `((issues "list" "--all" "--limit" "0")
                 (blocked "blocked")
                 (statuses "statuses")
                 (where "where")
                 ,@(and query `((query "query" ,query "--all" "--limit" "0")))))
         (pending (length jobs))
         (results nil)
         (errors nil))
    (setq mode-line-process '(:propertize " loading…" face beady-dim))
    (force-mode-line-update)
    (cl-flet ((done ()
                (setq pending (1- pending))
                (when (and (= pending 0) (buffer-live-p buffer))
                  (with-current-buffer buffer
                    (beady-list--receive results errors)))))
      (setq beady-list--processes
            (mapcar
             (lambda (job)
               (beady--run-async
                (cons "--json" (cdr job))
                (lambda (output)
                  (condition-case err
                      (push (cons (car job) (beady--parse-json output)) results)
                    (error (push (cons (car job) (error-message-string err)) errors)))
                  (done))
                (lambda (msg)
                  (push (cons (car job) msg) errors)
                  (done))))
             jobs)))))

(defun beady-list--loading-p ()
  "Return non-nil while the current list buffer is being refreshed."
  (seq-some #'process-live-p beady-list--processes))

(defun beady-list--receive (results errors)
  "Store the RESULTS of a refresh and redraw; report ERRORS."
  (setq beady-list--processes nil
        mode-line-process nil)
  (if-let* ((err (alist-get 'issues errors)))
      (setq beady-list--error err)
    (setq beady-list--error nil)
    (when-let* ((statuses (alist-get 'statuses results)))
      (beady--set-statuses beady--root statuses))
    (when-let* ((where (alist-get 'where results)))
      (beady--set-prefix beady--root where))
    (beady-list--set-data (alist-get 'issues results)
                          (alist-get 'blocked results)))
  (setq beady-list--query-error (alist-get 'query errors))
  (setq beady-list--query-ids
        (when (plist-get beady-list--filter :query)
          (let ((ids (make-hash-table :test #'equal)))
            (dolist (issue (let ((found (alist-get 'query results)))
                             (and (beady--json-array-p found) found)))
              (puthash (beady--id issue) t ids))
            ids)))
  (beady-list--render))

(defun beady-list--set-data (issues blocked)
  "Use ISSUES as the data of the buffer; BLOCKED is `bd blocked' output."
  (setq beady-list--row-cache nil)
  (setq beady-list--issues (and (beady--json-array-p issues) issues)
        beady-list--loaded t
        beady-list--statuses (beady--statuses beady--root)
        beady-list--table (make-hash-table :test #'equal
                                           :size (max 16 (length beady-list--issues)))
        beady-list--children (make-hash-table :test #'equal)
        beady-list--blocked (make-hash-table :test #'equal)
        beady-list--haystacks (make-hash-table :test #'equal))
  (dolist (issue beady-list--issues)
    (puthash (beady--id issue) issue beady-list--table))
  (dolist (issue (reverse beady-list--issues))
    (when-let* ((parent (beady--issue-parent issue)))
      (push (beady--id issue) (gethash parent beady-list--children))))
  (dolist (entry (and (beady--json-array-p blocked) blocked))
    (puthash (alist-get 'id entry) (or (alist-get 'blocked_by entry) '("?"))
             beady-list--blocked))
  (when beady-list--marks
    (maphash (lambda (id _)
               (unless (gethash id beady-list--table)
                 (remhash id beady-list--marks)))
             beady-list--marks)))

;;;; Predicates

(defun beady-list--status (issue)
  "Return the status of ISSUE."
  (alist-get 'status issue))

(defun beady-list--done-p (issue)
  "Return non-nil if ISSUE is closed (or in another done status)."
  (beady--status-done-p (beady-list--status issue) beady-list--statuses))

(defun beady-list--dep-blocked-p (issue)
  "Return non-nil if ISSUE is blocked by an open dependency."
  (and beady-list--blocked
       (gethash (beady--id issue) beady-list--blocked)
       (not (beady-list--done-p issue))))

(defun beady-list--ready-p (issue)
  "Return non-nil if ISSUE is ready to be worked on.
That is: in an active status, not blocked and not deferred to the future."
  (and (equal (beady--status-category (beady-list--status issue) beady-list--statuses)
              "active")
       (not (beady-list--dep-blocked-p issue))
       (let ((until (beady--time (alist-get 'defer_until issue))))
         (or (null until) (time-less-p until nil)))))

(defun beady-list--blocked-p (issue)
  "Return non-nil if ISSUE has the blocked status or open blockers."
  (and (not (beady-list--done-p issue))
       (or (equal (beady-list--status issue) "blocked")
           (beady-list--dep-blocked-p issue))))

(defun beady-list--lane (issue)
  "Return the board lane of ISSUE, a key of `beady-list--lanes'."
  (let ((category (beady--status-category (beady-list--status issue)
                                          beady-list--statuses)))
    (cond ((beady-list--done-p issue) 'closed)
          ((beady-list--blocked-p issue) 'blocked)
          ((equal category "wip") 'in-progress)
          ((equal category "frozen") 'deferred)
          ((beady-list--ready-p issue) 'ready)
          (t 'open))))

(defun beady-list--descendants (id)
  "Return a hash table of ID and all its descendants."
  (let ((seen (make-hash-table :test #'equal))
        (todo (list id)))
    (while todo
      (let ((next (pop todo)))
        (unless (gethash next seen)
          (puthash next t seen)
          (setq todo (append (gethash next beady-list--children) todo)))))
    seen))

(defun beady-list--haystack (issue)
  "Return the lower-cased text searched for ISSUE."
  (let ((id (beady--id issue)))
    (or (gethash id beady-list--haystacks)
        (puthash id
                 (downcase
                  (mapconcat (lambda (field)
                               (let ((value (alist-get field issue)))
                                 (if (listp value)
                                     (string-join value " ")
                                   (format "%s" value))))
                             beady-list-search-fields "\n"))
                 beady-list--haystacks))))

(defun beady-list--search-match-p (issue terms)
  "Return non-nil if every string in TERMS occurs in ISSUE."
  (let ((haystack (beady-list--haystack issue)))
    (seq-every-p (lambda (term) (string-search term haystack)) terms)))

(defun beady-list--status-match-p (issue preset)
  "Return non-nil if ISSUE matches the status filter PRESET."
  (pcase preset
    ((or 'nil 'all) t)
    ('open (not (beady-list--done-p issue)))
    ('closed (beady-list--done-p issue))
    ('ready (beady-list--ready-p issue))
    ('blocked (beady-list--blocked-p issue))
    ((pred listp) (member (beady-list--status issue) preset))
    (_ t)))

(defun beady-list--filter-function ()
  "Return a predicate implementing the current filter."
  (let* ((filter beady-list--filter)
         (status (plist-get filter :status))
         (types (plist-get filter :types))
         (priorities (plist-get filter :priorities))
         (labels (plist-get filter :labels))
         (assignees (plist-get filter :assignees))
         (parent (plist-get filter :parent))
         (family (and parent (beady-list--descendants parent)))
         (terms (and (plist-get filter :search)
                     (split-string (downcase (plist-get filter :search)) "[ \t]+" t)))
         (query (plist-get filter :query))
         (query-ids beady-list--query-ids))
    (lambda (issue)
      (and (beady-list--status-match-p issue status)
           (or (null types) (member (alist-get 'issue_type issue) types))
           (or (null priorities) (memql (alist-get 'priority issue) priorities))
           (or (null labels) (seq-intersection labels (alist-get 'labels issue)))
           (or (null assignees) (member (or (alist-get 'assignee issue) "") assignees))
           (or (null family) (gethash (beady--id issue) family))
           (or (null terms) (beady-list--search-match-p issue terms))
           (or (null query) (and query-ids (gethash (beady--id issue) query-ids)))))))

;;;; Sorting

(defun beady-list--sort-spec (field)
  "Return (GETTER . DESCENDING) for sorting by FIELD."
  (pcase field
    ('priority (cons (lambda (i) (alist-get 'priority i)) nil))
    ('updated (cons (lambda (i) (alist-get 'updated_at i)) t))
    ('created (cons (lambda (i) (alist-get 'created_at i)) t))
    ('closed (cons (lambda (i) (alist-get 'closed_at i)) t))
    ('due (cons (lambda (i) (alist-get 'due_at i)) nil))
    ('id (cons #'beady--id nil))
    ('title (cons (lambda (i) (downcase (or (alist-get 'title i) ""))) nil))
    ('status (let ((order (beady--ordered-statuses beady-list--statuses)))
               (cons (lambda (i) (beady--rank (beady-list--status i) order)) nil)))
    ('type (cons (lambda (i) (beady--rank (alist-get 'issue_type i) beady--type-order)) nil))
    ('assignee (cons (lambda (i) (let ((a (alist-get 'assignee i)))
                                   (and a (not (string-empty-p a)) (downcase a))))
                     nil))
    (_ (error "Unknown sort field %S" field))))

(defun beady-list--compare (a b)
  "Compare the sort values A and B; return -1, 0 or 1."
  (cond ((equal a b) 0)
        ((and (numberp a) (numberp b)) (if (< a b) -1 1))
        ((and (stringp a) (stringp b)) (if (string-version-lessp a b) -1 1))
        (t 0)))

(defun beady-list--tiebreak (a b)
  "Return non-nil if issue A sorts before B when their sort keys are equal."
  (let ((c (beady-list--compare (alist-get 'priority a) (alist-get 'priority b))))
    (if (/= c 0)
        (< c 0)
      (let ((c (beady-list--compare (alist-get 'updated_at b) (alist-get 'updated_at a))))
        (if (/= c 0)
            (< c 0)
          (string-version-lessp (beady--id a) (beady--id b)))))))

(defun beady-list--sort-issues (issues field reverse)
  "Return ISSUES sorted by FIELD, in REVERSE order if non-nil.
Beads without a value for FIELD always come last."
  (pcase-let* ((`(,getter . ,descending) (beady-list--sort-spec field))
               (flip (if reverse (not descending) descending)))
    (mapcar #'cdr
            (sort (mapcar (lambda (issue) (cons (funcall getter issue) issue)) issues)
                  (lambda (x y)
                    (let ((a (car x)) (b (car y)))
                      (cond ((and (null a) (null b)) (beady-list--tiebreak (cdr x) (cdr y)))
                            ((null a) nil)
                            ((null b) t)
                            (t (let ((c (beady-list--compare a b)))
                                 (if (= c 0)
                                     (beady-list--tiebreak (cdr x) (cdr y))
                                   (if flip (> c 0) (< c 0))))))))))))

;;;; Grouping

(defun beady-list--group-entries (issue)
  "Return a list of (KEY RANK TITLE) for the groups ISSUE belongs to."
  (pcase beady-list--group
    ('status
     (let ((status (or (beady-list--status issue) "unknown")))
       (list (list status
                   (beady--rank status (beady--ordered-statuses beady-list--statuses))
                   (beady-list--format-status status)))))
    ('lane
     (let ((lane (beady-list--lane issue)))
       (list (list lane (beady--rank lane (mapcar #'car beady-list--lanes))
                   (cdr (assq lane beady-list--lanes))))))
    ('priority
     (let ((p (alist-get 'priority issue)))
       (list (list (or p -1) (or p 99)
                   (concat (beady--format-priority p) " " (beady--priority-name p))))))
    ('type
     (let ((type (alist-get 'issue_type issue)))
       (if (and type (not (string-empty-p type)))
           (list (list type (beady--rank type beady--type-order) (beady--format-type type)))
         (list (list "" 99 "No type")))))
    ('assignee
     (let ((a (alist-get 'assignee issue)))
       (if (and a (not (string-empty-p a)))
           (list (list a 0 (propertize a 'face 'beady-assignee)))
         (list (list "" 1 "Unassigned")))))
    ('label
     (or (mapcar (lambda (label) (list label 0 (propertize label 'face 'beady-label)))
                 (alist-get 'labels issue))
         (list (list "" 1 "No labels"))))
    ('parent
     (let* ((id (beady--id issue))
            (key (or (beady--issue-parent issue)
                     (and (gethash id beady-list--children) id))))
       (if key
           (let ((parent (gethash key beady-list--table)))
             (list (list key (if parent (or (alist-get 'priority parent) 9) 9)
                         (beady-list--parent-title key parent))))
         (list (list "" 99 "No parent")))))))

(defun beady-list--parent-title (id parent)
  "Return the group title for parent ID whose data is PARENT."
  (let* ((children (gethash id beady-list--children))
         (closed (seq-count (lambda (child)
                              (let ((issue (gethash child beady-list--table)))
                                (and issue (beady-list--done-p issue))))
                            children)))
    (concat (propertize id 'face 'beady-id) "  "
            (or (alist-get 'title parent) "")
            (propertize (format "  %d/%d closed" closed (length children))
                        'face 'beady-group-count))))

(defun beady-list--groups (issues)
  "Split the sorted ISSUES into groups.
Return a list of (KEY TITLE ISSUES) in display order."
  (let ((table (make-hash-table :test #'equal))
        (meta nil))
    (dolist (issue issues)
      (dolist (entry (beady-list--group-entries issue))
        (let ((key (car entry)))
          (unless (gethash key table) (push entry meta))
          (push issue (gethash key table)))))
    (mapcar (lambda (entry)
              (let* ((key (car entry))
                     (members (nreverse (gethash key table))))
                ;; Put the parent itself first in its own group.
                (when (eq beady-list--group 'parent)
                  (when-let* ((self (seq-find (lambda (i) (equal (beady--id i) key)) members)))
                    (setq members (cons self (delq self members)))))
                (list key (nth 2 entry) members)))
            (sort (nreverse meta)
                  (lambda (a b)
                    (let ((c (beady-list--compare (nth 1 a) (nth 1 b))))
                      (if (/= c 0)
                          (< c 0)
                        (string-version-lessp (format "%s" (car a))
                                              (format "%s" (car b))))))))))

(defun beady-list--tree-rows (issues)
  "Arrange ISSUES hierarchically.
Return a list of (ISSUE . PREFIX) where PREFIX draws the tree guides.
Beads whose parent is not among ISSUES are roots."
  (let ((present (make-hash-table :test #'equal))
        (kids (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal))
        (roots nil)
        (rows nil))
    (dolist (issue issues)
      (puthash (beady--id issue) t present))
    (dolist (issue issues)
      (let ((parent (beady--issue-parent issue)))
        (if (and parent (gethash parent present)
                 (not (equal parent (beady--id issue))))
            (push issue (gethash parent kids))
          (push issue roots))))
    (cl-labels ((walk (issue guide prefix)
                  (unless (gethash (beady--id issue) seen)
                    (puthash (beady--id issue) t seen)
                    (push (cons issue prefix) rows)
                    (let ((children (reverse (gethash (beady--id issue) kids))))
                      (while children
                        (let ((child (pop children)))
                          (walk child
                                (concat guide (if children "│  " "   "))
                                (concat guide (if children "├─ " "└─ ")))))))))
      (dolist (root (nreverse roots))
        (walk root "" "")))
    ;; Beads caught in a parent cycle are never reached from a root.
    (dolist (issue issues)
      (unless (gethash (beady--id issue) seen)
        (push (cons issue "") rows)))
    (nreverse rows)))

;;;; Rendering

(defun beady-list--visible-issues ()
  "Return the issues matching the current filter, sorted."
  (beady-list--sort-issues (seq-filter (beady-list--filter-function) beady-list--issues)
                           beady-list--sort beady-list--sort-reverse))

(defun beady-list--age (issue)
  "Return the age string of ISSUE."
  (or (beady--format-age (beady--time (alist-get beady-list-age-field issue))
                         beady-list--now)
      ""))

(defun beady-list--active-columns ()
  "Return the columns displayed in the current buffer.
This is `beady-list-columns' without the ID column when IDs are hidden."
  (if (eq beady-list-id-style 'hidden)
      (delq 'id (copy-sequence beady-list-columns))
    beady-list-columns))

(defun beady-list--trailing-p (column)
  "Return non-nil if COLUMN is displayed after the title."
  (let ((after-title nil))
    (catch 'result
      (dolist (c (beady-list--active-columns))
        (when (eq c column)
          (throw 'result after-title))
        (when (eq c 'title)
          (setq after-title t)))
      nil)))

(defun beady-list--id-text (id)
  "Return ID as displayed according to `beady-list-id-style'."
  (if (eq beady-list-id-style 'full) id (beady--short-id id)))

(defun beady-list--status-cell-text (status)
  "Return the unpadded status text of STATUS in the list."
  (pcase beady-list-status-style
    ('icon (beady--status-icon status))
    (_ (concat (beady--status-icon status) " " (beady-list--status-name status)))))

(defun beady-list--status-name (status)
  "Return the status name of STATUS for the current list style."
  (if (eq beady-list-status-style 'full)
      (or status "?")
    (beady--status-label status)))

(defun beady-list--format-status (status)
  "Return STATUS formatted for the list, propertized."
  (propertize (beady-list--status-cell-text status)
              'face (beady--status-face status)))

(defun beady-list--column-title (column)
  "Return the header title of COLUMN for the current display options."
  (if (and (eq column 'status) (eq beady-list-status-style 'icon))
      " "
    (alist-get column beady-list--column-titles)))

(defun beady-list--raw-cell (issue column)
  "Return the unpadded text of COLUMN for ISSUE, used to size columns."
  (pcase column
    ('id (beady-list--id-text (beady--id issue)))
    ('status (if (eq beady-list-status-style 'icon)
                 "x"
               (concat "x " (beady-list--status-name (beady-list--status issue)))))
    ('type (or (alist-get 'issue_type issue) ""))
    ('assignee (concat "@" (or (alist-get 'assignee issue) "")))
    ('age (beady-list--age issue))
    (_ "")))

(defun beady-list--compute-widths (issues)
  "Return an alist of column widths suitable for ISSUES."
  (let ((widths (list (cons 'mark 1) (cons 'priority 3)))
        (columns (beady-list--active-columns)))
    (dolist (column '(id status type assignee age))
      (when (memq column columns)
        (let ((width (string-width (beady-list--column-title column))))
          (dolist (issue issues)
            (setq width (max width (string-width (beady-list--raw-cell issue column)))))
          (push (cons column (min width (or (alist-get column beady-list-column-max-widths)
                                            width)))
                widths))))
    (when (and beady-list-title-width (memq 'title columns))
      (push (cons 'title beady-list-title-width) widths))
    widths))

(defun beady-list--badges (issue)
  "Return the comment and dependency count badges of ISSUE."
  (let ((comments (or (alist-get 'comment_count issue) 0))
        (dependencies (or (alist-get 'dependency_count issue) 0)))
    (concat (and (> comments 0)
                 (propertize (format " [%dc]" comments) 'face 'beady-dim))
            (and (> dependencies 0)
                 (propertize (format " [dep:%d]" dependencies) 'face 'beady-dim)))))

(defun beady-list--cell (issue column prefix)
  "Return the text of COLUMN for ISSUE; PREFIX is its tree guide."
  (let* ((id (beady--id issue))
         (marked (and beady-list--marks (gethash id beady-list--marks)))
         (width (and (not (beady-list--trailing-p column))
                     (alist-get column beady-list--widths))))
    (pcase column
      ('mark (if marked (propertize "*" 'face 'beady-marked) " "))
      ('id (beady--pad (propertize (beady-list--id-text id)
                                   'face (if marked 'beady-marked 'beady-id))
                       width))
      ('priority (beady--pad (beady--format-priority (alist-get 'priority issue)) width))
      ('status
       (beady--pad
        (let* ((status (beady-list--status issue))
               (blockers (and (beady-list--dep-blocked-p issue)
                              (gethash id beady-list--blocked)))
               (text (if blockers
                         (if (eq beady-list-status-style 'icon)
                             beady-blocked-indicator
                           (concat beady-blocked-indicator " "
                                   (beady-list--status-name status)))
                       (beady-list--status-cell-text status)))
               (help (if blockers
                         (format "%s blocked by %s" (or status "?")
                                 (string-join blockers ", "))
                       (or status "?"))))
          (propertize text
                      'face (if blockers 'beady-status-blocked
                              (beady--status-face status))
                      'help-echo help))
        width))
      ('type (beady--pad (beady--format-type (alist-get 'issue_type issue)) width))
      ('assignee (beady--pad (beady--format-assignee (alist-get 'assignee issue))
                             width))
      ('age (let ((text (propertize (beady-list--age issue) 'face 'beady-date)))
              (if width
                  (string-pad (truncate-string-to-width text width) width nil t)
                text)))
      ('title
       (let ((text (concat
                    (propertize prefix 'face 'beady-tree)
                    (propertize (or (alist-get 'title issue) "")
                                'face (if (beady-list--done-p issue)
                                          'beady-closed
                                        'beady-title))
                    (beady-list--badges issue))))
         (if width (beady--pad text width) text)))
      ('labels (beady--format-labels (alist-get 'labels issue)))
      (_ ""))))

(defun beady-list--prepare-rows ()
  "Make sure the column widths and row cache are current.
Widths are computed from all beads, so columns stay put while
filtering.  The cache is dropped every minute so that ages stay right."
  (let ((key (list (truncate (float-time) 60) beady-list-columns
                   beady-list-title-width beady-list-column-max-widths
                   beady-list-id-style beady-list-status-style
                   (beady--project-prefix))))
    (unless (and beady-list--row-cache (equal key beady-list--row-cache-key))
      (setq beady-list--row-cache (make-hash-table :test #'equal)
            beady-list--row-cache-key key
            beady-list--now (current-time)
            beady-list--widths (beady-list--compute-widths beady-list--issues)))))

(defun beady-list--forget-row (id)
  "Drop the cached rows of ID."
  (when beady-list--row-cache
    (remhash id beady-list--row-cache)))

(defun beady-list--row (issue prefix)
  "Return the line displaying ISSUE with tree guide PREFIX."
  (let* ((id (beady--id issue))
         (rows (gethash id beady-list--row-cache)))
    (or (cdr (assoc prefix rows))
        (let ((lead nil) (trail nil) (trailing nil))
          (dolist (column (beady-list--active-columns))
            (let ((cell (beady-list--cell issue column prefix)))
              (if trailing
                  (unless (string-empty-p cell)
                    (push cell trail))
                (push cell lead))
              (when (eq column 'title)
                (setq trailing t))))
          (let ((row (string-trim-right
                      (concat (mapconcat #'identity (nreverse lead) " ")
                              (when trail
                                (concat "  " (mapconcat #'identity (nreverse trail)
                                                        "  ")))))))
            (puthash id (cons (cons prefix row) rows) beady-list--row-cache)
            row)))))

(defun beady-list--insert-row (issue prefix group)
  "Insert the line for ISSUE with tree guide PREFIX belonging to GROUP."
  (let ((start (point)))
    (insert (beady-list--row issue prefix) "\n")
    (add-text-properties start (point)
                         (list 'beady-id (beady--id issue)
                               'beady-prefix prefix
                               'beady-in-group group))))

(defun beady-list--header-text ()
  "Return the column header text for the current widths."
  (let ((parts nil)
        (after-title nil))
    (dolist (column (beady-list--active-columns))
      (let ((title (beady-list--column-title column))
            (width (alist-get column beady-list--widths)))
        (unless after-title
          (push (if width (beady--pad title width) title) parts))
        (when (and (eq column 'title) (not width))
          (setq after-title t))))
    (string-trim-right (string-join (nreverse parts) " "))))

(defun beady-list--insert-column-header ()
  "Insert the aligned table header and its rule line at point."
  (insert beady-list--header "\n"
          (propertize (make-string (string-width beady-list--header) ?─)
                      'face 'beady-dim)
          "\n"))

(defun beady-list--header-line ()
  "Return the header line of the list buffer.
Return nil when the column header is displayed in the buffer."
  (unless beady-list-show-column-header
    (when beady-list--header
      (concat (propertize " " 'display '(space :align-to 0))
              (and (boundp 'header-line-indent) header-line-indent)
              beady-list--header))))

(defun beady-list--describe-status-filter (status)
  "Return a description of the status filter STATUS."
  (pcase status
    ((or 'nil 'all) "all")
    ('open "open (not closed)")
    ((pred symbolp) (symbol-name status))
    (_ (string-join status ","))))

(defun beady-list--describe-filters ()
  "Return a list of (NAME . VALUE) describing the active filters."
  (let ((filter beady-list--filter)
        (result nil))
    (cl-flet ((add (name value) (push (cons name value) result)))
      (add "Show" (beady-list--describe-status-filter (plist-get filter :status)))
      (when-let* ((v (plist-get filter :types))) (add "Type" (string-join v ",")))
      (when-let* ((v (plist-get filter :priorities)))
        (add "Priority" (mapconcat (lambda (p) (format "P%d" p)) v ",")))
      (when-let* ((v (plist-get filter :labels))) (add "Label" (string-join v ",")))
      (when-let* ((v (plist-get filter :assignees)))
        (add "Assignee" (mapconcat (lambda (a) (if (string-empty-p a) "unassigned" a)) v ",")))
      (when-let* ((v (plist-get filter :parent))) (add "Under" v))
      (when-let* ((v (plist-get filter :search))) (add "Search" (format "\"%s\"" v)))
      (when-let* ((v (plist-get filter :query))) (add "Query" (format "\"%s\"" v))))
    (nreverse result)))

(eval-and-compile
  (defun beady-list--sort-name (field)
    "Return a readable name for sort FIELD."
    (pcase field
      ('updated "last update") ('created "creation") ('closed "close date")
      ('due "due date") (_ (symbol-name field))))

  (defun beady-list--group-name (group)
    "Return a readable name for GROUP."
    (pcase group
      ('nil "none") ('lane "board lanes") ('parent "epic") (_ (symbol-name group)))))

(defun beady-list--status-counts ()
  "Return a string with the number of beads per status."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (issue beady-list--issues)
      (cl-incf (gethash (beady-list--status issue) counts 0)))
    (mapconcat #'identity
               (delq nil
                     (mapcar (lambda (status)
                               (let ((n (gethash status counts 0)))
                                 (when (> n 0)
                                   (propertize (format "%s %s %d"
                                                       (beady--status-icon status)
                                                       (beady--status-label status) n)
                                               'face (beady--status-face status)
                                               'help-echo status))))
                             (beady--ordered-statuses beady-list--statuses)))
               "  ")))

(defun beady-list--insert-summary (shown)
  "Insert the summary of the view, with SHOWN beads visible."
  (insert (propertize (beady--project-name beady--root) 'face 'bold)
          (propertize (format "  %d of %d beads   " shown (length beady-list--issues))
                      'face 'beady-dim)
          (beady-list--status-counts) "\n")
  (let ((items (append (beady-list--describe-filters)
                       (list (cons "Sort" (concat (beady-list--sort-name beady-list--sort)
                                                  (if beady-list--sort-reverse " (reversed)" "")))
                             (cons "Group" (beady-list--group-name beady-list--group)))
                       (and beady-list--tree (list (cons "Tree" "on"))))))
    (insert (mapconcat (lambda (item)
                         (concat (propertize (car item) 'face 'beady-dim) " " (cdr item)))
                       items "   ")
            "\n"))
  (when beady-list--query-error
    (insert (propertize (concat "Query failed: " beady-list--query-error) 'face 'error) "\n"))
  (when beady-list-show-hints
    (let ((hints (beady--hints '((beady-list-dispatch . "commands")
                                 (beady-list-view-menu . "filter/sort/group")
                                 (beady-list-search . "search")
                                 (beady-list-show . "open")
                                 (beady-status-menu . "status")
                                 (beady-create-menu . "new")))))
      (unless (string-empty-p hints)
        (insert hints "\n"))))
  (insert "\n"))

(defun beady-list--save-position ()
  "Return a description of the position of point for restoring it."
  (list (beady-list--id-at-point)
        (beady-list--line-property 'beady-group)
        (line-number-at-pos)
        (mapcar (lambda (window)
                  (cons window (count-lines (window-start window) (window-point window))))
                (get-buffer-window-list nil nil t))))

(defun beady-list--find (property value)
  "Return the start of the first text with PROPERTY equal to VALUE."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward property value t)))
      (prop-match-beginning match))))

(defun beady-list--first-row ()
  "Return the position of the first bead or group line, or nil."
  (save-excursion
    (goto-char (point-min))
    (let ((pos nil))
      (while (and (not pos) (not (eobp)))
        (if (or (get-text-property (point) 'beady-id)
                (get-text-property (point) 'beady-group))
            (setq pos (point))
          (forward-line 1)))
      pos)))

(defun beady-list--restore-position (position)
  "Move point back to POSITION from `beady-list--save-position'."
  (pcase-let ((`(,id ,group ,line ,windows) position))
    (goto-char (or (and beady-list--focus
                        (prog1 (beady-list--find 'beady-id beady-list--focus)
                          (setq beady-list--focus nil)))
                   (and id (beady-list--find 'beady-id id))
                   (and group (beady-list--find 'beady-group group))
                   (and (not beady-list--initialized) beady-list--loaded
                        (beady-list--first-row))
                   (progn (goto-char (point-min))
                          (forward-line (1- line))
                          (point))))
    (when beady-list--loaded
      (setq beady-list--initialized t))
    (dolist (entry windows)
      (when (window-live-p (car entry))
        (set-window-point (car entry) (point))
        (beady--restore-window-start (car entry) (cdr entry))))))

(defun beady-list--render ()
  "Redraw the current list buffer from the loaded data."
  (let ((inhibit-read-only t)
        (position (beady-list--save-position)))
    (erase-buffer)
    (setq beady-list--displayed nil
          beady-list--group-keys nil
          beady-list--header nil)
    (cond
     ((and beady-list--error (not beady-list--loaded))
      (insert (propertize "Could not load beads" 'face 'error)
              (format " from %s\n\n" (abbreviate-file-name beady--root))
              beady-list--error "\n\n"
              (substitute-command-keys "Press \\[beady-list-refresh] to try again.\n")))
     ((not beady-list--loaded)
      (insert (propertize (format "Loading beads from %s…\n"
                                  (abbreviate-file-name beady--root))
                          'face 'beady-dim)))
     (t
      (let* ((visible (beady-list--visible-issues))
             (groups (if beady-list--group
                         (beady-list--groups visible)
                       (list (list nil nil visible))))
             (displayed nil))
        (beady-list--prepare-rows)
        (setq beady-list--header (beady-list--header-text))
        (when beady-list-show-summary
          (beady-list--insert-summary (length visible)))
        (when beady-list--error
          (insert (propertize (concat "Refresh failed: " beady-list--error) 'face 'error)
                  "\n\n"))
        (cond
         ((null beady-list--issues)
          (insert (propertize "This project has no beads yet." 'face 'beady-dim) "\n"
                  (substitute-command-keys
                   "Press \\[beady-create-menu] to create one.\n")))
         ((null visible)
          (insert (propertize "No beads match the current filters." 'face 'beady-dim)
                  "\n"
                  (substitute-command-keys
                   "Press \\[beady-list-view-menu] to change the filters.\n")))
         (t
          (when beady-list-show-column-header
            (beady-list--insert-column-header))
          (let ((first t))
            (pcase-dolist (`(,key ,title ,members) groups)
              (when beady-list--group
                (let ((collapsed (member key beady-list--collapsed))
                      (start (point)))
                  (unless first (insert "\n") (setq start (point)))
                  (push key beady-list--group-keys)
                  (insert (propertize (concat (if collapsed "▸ " "▾ ") title)
                                      'face 'beady-group-heading)
                          " " (propertize (format "(%d)" (length members))
                                          'face 'beady-group-count)
                          "\n")
                  (add-text-properties start (point) (list 'beady-group key))))
              (setq first nil)
              (unless (and beady-list--group (member key beady-list--collapsed))
                (pcase-dolist (`(,issue . ,prefix)
                               (if beady-list--tree
                                   (beady-list--tree-rows members)
                                 (mapcar (lambda (i) (cons i "")) members)))
                  (beady-list--insert-row issue prefix key)
                  (push (beady--id issue) displayed)))))))
        (setq beady-list--displayed (delete-dups (nreverse displayed))
              beady-list--group-keys (nreverse beady-list--group-keys)))))
    ;; Without a final newline the last line is a bead, so that going to
    ;; the end of the buffer (e.g. with evil's G) lands on one.
    (when (eq (char-before (point-max)) ?\n)
      (delete-region (1- (point-max)) (point-max)))
    (beady-list--restore-position position)))

(defun beady-list--redraw-line ()
  "Redraw the line at point, e.g. after changing its mark."
  (when-let* ((id (beady-list--id-at-point))
              (issue (gethash id beady-list--table)))
    (let* ((inhibit-read-only t)
           (start (line-beginning-position))
           (last (= (line-end-position) (point-max)))
           (prefix (get-text-property start 'beady-prefix))
           (group (get-text-property start 'beady-in-group))
           (column (current-column)))
      (delete-region start (line-beginning-position 2))
      (goto-char start)
      (beady-list--insert-row issue prefix group)
      (when last (delete-char -1))
      (goto-char start)
      (move-to-column column))))

;;;; Point and navigation

(defun beady-list--line-property (property)
  "Return PROPERTY of the line at point.
Rows carry their properties on the whole line, so looking at the start
of the line works wherever point is, including the end of the buffer."
  (get-text-property (line-beginning-position) property))

(defun beady-list--id-at-point ()
  "Return the ID of the bead at point, or nil."
  (beady-list--line-property 'beady-id))

(defun beady-list--ids-in-region (beg end)
  "Return the IDs of the beads on lines between BEG and END."
  (save-excursion
    (let ((ids nil))
      (goto-char beg)
      (beginning-of-line)
      (while (and (< (point) end) (not (eobp)))
        (when-let* ((id (get-text-property (point) 'beady-id)))
          (push id ids))
        (forward-line 1))
      (delete-dups (nreverse ids)))))

(defun beady-list--marked-ids ()
  "Return the marked IDs, in display order."
  (when (and beady-list--marks (> (hash-table-count beady-list--marks) 0))
    (let ((ids (seq-filter (lambda (id) (gethash id beady-list--marks))
                           beady-list--displayed)))
      (maphash (lambda (id _) (unless (member id ids) (setq ids (append ids (list id)))))
               beady-list--marks)
      ids)))

(defun beady-list--targets ()
  "Return the IDs that commands act on: marked, in region or at point."
  (or (beady-list--marked-ids)
      (and (use-region-p)
           (let ((bounds (beady--region-bounds)))
             (beady-list--ids-in-region (car bounds) (cdr bounds))))
      (when-let* ((id (beady-list--id-at-point)))
        (list id))))

(defun beady-list--move (property n)
  "Move to the Nth next line that has PROPERTY; backwards if N is negative."
  (let ((step (if (< n 0) -1 1))
        (pos nil))
    (save-excursion
      (dotimes (_ (abs n))
        (let ((found nil))
          (while (and (not found) (zerop (forward-line step))
                      (not (and (> step 0) (eobp))))
            (when (get-text-property (point) property)
              (setq found (point))))
          (when found (setq pos found)))))
    (if pos
        (goto-char pos)
      (user-error "No %s %s" (if (> n 0) "next" "previous")
                  (if (eq property 'beady-group) "group" "bead")))))

(defun beady-list-next (&optional n)
  "Move to the next bead, or the Nth next."
  (interactive "p")
  (beady-list--move 'beady-id (or n 1)))

(defun beady-list-previous (&optional n)
  "Move to the previous bead, or the Nth previous."
  (interactive "p")
  (beady-list--move 'beady-id (- (or n 1))))

(defun beady-list-next-group (&optional n)
  "Move to the next group heading, or the Nth next."
  (interactive "p")
  (beady-list--move 'beady-group (or n 1)))

(defun beady-list-previous-group (&optional n)
  "Move to the previous group heading, or the Nth previous."
  (interactive "p")
  (beady-list--move 'beady-group (- (or n 1))))

(defun beady-list-goto-id (id)
  "Move point to the line of bead ID, if it is displayed."
  (when-let* ((pos (beady-list--find 'beady-id id)))
    (goto-char pos)
    (dolist (window (get-buffer-window-list nil nil t))
      (set-window-point window pos))
    pos))

(defun beady-list-neighbor-id (buffer id n)
  "Return the ID N positions away from ID in list BUFFER."
  (with-current-buffer buffer
    (let* ((ids beady-list--displayed)
           (pos (seq-position ids id))
           (target (and pos (+ pos n))))
      (cond ((null pos) (car ids))
            ((and (>= target 0) (< target (length ids))) (nth target ids))))))

;;;; Groups

(defun beady-list--group-at-point ()
  "Return the key of the group at point."
  (or (beady-list--line-property 'beady-group)
      (and beady-list--group (beady-list--line-property 'beady-in-group))))

(defun beady-list--toggle-groups (keys collapse)
  "Collapse KEYS if COLLAPSE is non-nil, otherwise expand them."
  (dolist (key keys)
    (setq beady-list--collapsed (delete key beady-list--collapsed))
    (when collapse (push key beady-list--collapsed))))

(defun beady-list-toggle-group ()
  "Collapse or expand the group at point."
  (interactive)
  (beady-list--ensure)
  (unless beady-list--group
    (user-error "The list is not grouped; use %s to group it"
                (or (beady--key-for 'beady-list-view-menu) "M-x beady-list-view-menu")))
  (let ((key (or (beady-list--group-at-point) (user-error "Not on a group"))))
    (beady-list--toggle-groups (list key) (not (member key beady-list--collapsed)))
    (beady-list--render)
    (goto-char (beady-list--find 'beady-group key))))

(defun beady-list-expand-group ()
  "Expand the group at point."
  (interactive)
  (beady-list--ensure)
  (when-let* ((key (beady-list--group-at-point)))
    (beady-list--toggle-groups (list key) nil)
    (beady-list--render)))

(defun beady-list-collapse-group ()
  "Collapse the group at point."
  (interactive)
  (beady-list--ensure)
  (when-let* ((key (beady-list--group-at-point)))
    (beady-list--toggle-groups (list key) t)
    (beady-list--render)
    (goto-char (beady-list--find 'beady-group key))))

(defun beady-list-expand-all ()
  "Expand all groups."
  (interactive)
  (beady-list--ensure)
  (setq beady-list--collapsed nil)
  (beady-list--render))

(defun beady-list-collapse-all ()
  "Collapse all groups."
  (interactive)
  (beady-list--ensure)
  (setq beady-list--collapsed (copy-sequence beady-list--group-keys))
  (beady-list--render))

(defun beady-list-toggle-all-groups ()
  "Collapse all groups, or expand them all if they already are collapsed."
  (interactive)
  (beady-list--ensure)
  (if (seq-every-p (lambda (key) (member key beady-list--collapsed))
                   beady-list--group-keys)
      (beady-list-expand-all)
    (beady-list-collapse-all)))

;;;; Marks

(defun beady-list--set-mark (mark n)
  "Set the mark of N beads (or the region) to MARK and move down."
  (beady-list--ensure)
  (if (use-region-p)
      (let* ((bounds (beady--region-bounds))
             (ids (beady-list--ids-in-region (car bounds) (cdr bounds))))
        (dolist (id ids)
          (if mark (puthash id t beady-list--marks) (remhash id beady-list--marks))
          (beady-list--forget-row id))
        (beady--deactivate-selection)
        (beady-list--render))
    (dotimes (_ n)
      (when-let* ((id (beady-list--id-at-point)))
        (if mark (puthash id t beady-list--marks) (remhash id beady-list--marks))
        (beady-list--forget-row id)
        (if (eq beady-list--group 'label)
            (beady-list--render)
          (beady-list--redraw-line)))
      (ignore-errors (beady-list-next 1)))))

(defun beady-list-mark (&optional n)
  "Mark the bead at point (or N beads, or the region) and move down.
Commands that change beads act on all marked beads."
  (interactive "p")
  (beady-list--set-mark t (or n 1)))

(defun beady-list-unmark (&optional n)
  "Unmark the bead at point (or N beads, or the region) and move down."
  (interactive "p")
  (beady-list--set-mark nil (or n 1)))

(defun beady-list-unmark-all ()
  "Remove all marks."
  (interactive)
  (beady-list--ensure)
  (clrhash beady-list--marks)
  (setq beady-list--row-cache nil)
  (beady-list--render))

(defun beady-list-toggle-marks ()
  "Toggle the marks of all displayed beads."
  (interactive)
  (beady-list--ensure)
  (dolist (id beady-list--displayed)
    (if (gethash id beady-list--marks)
        (remhash id beady-list--marks)
      (puthash id t beady-list--marks))
    (beady-list--forget-row id))
  (beady-list--render))

;;;; Showing beads

(defun beady-list--id-or-error ()
  "Return the ID at point or signal an error."
  (or (beady-list--id-at-point) (user-error "No bead at point")))

(defun beady-list-show ()
  "Show the bead at point, or toggle the group at point."
  (interactive)
  (beady-list--ensure)
  (if (and (beady-list--line-property 'beady-group) (not (beady-list--id-at-point)))
      (beady-list-toggle-group)
    (beady-show-issue (beady-list--id-or-error) beady--root)))

(defconst beady-list--other-window-action
  '((display-buffer-reuse-window display-buffer-use-some-window display-buffer-pop-up-window)
    (inhibit-same-window . t))
  "Action used to show beads next to the list.")

(defun beady-list-show-other-window ()
  "Show the bead at point in another window and select it."
  (interactive)
  (beady-list--ensure)
  (beady-show-issue (beady-list--id-or-error) beady--root beady-list--other-window-action))

(defun beady-list-display ()
  "Show the bead at point in another window without selecting it."
  (interactive)
  (beady-list--ensure)
  (beady-show-issue (beady-list--id-or-error) beady--root
                    beady-list--other-window-action t))

(defvar beady-list--follow-timer nil "Timer of `beady-list-follow-mode'.")
(defvar-local beady-list--follow-last nil "Last bead shown by follow mode.")

(defun beady-list--follow ()
  "Schedule showing the bead at point for `beady-list-follow-mode'."
  (let ((id (beady-list--id-at-point))
        (buffer (current-buffer)))
    (when (and id (not (equal id beady-list--follow-last)))
      (setq beady-list--follow-last id)
      (when (timerp beady-list--follow-timer)
        (cancel-timer beady-list--follow-timer))
      (setq beady-list--follow-timer
            (run-with-idle-timer
             0.2 nil
             (lambda ()
               (when (and (buffer-live-p buffer) (eq (current-buffer) buffer))
                 (beady-show-issue id beady--root beady-list--other-window-action t))))))))

(define-minor-mode beady-list-follow-mode
  "Show the bead at point in another window while moving in the list."
  :lighter " Follow"
  (if beady-list-follow-mode
      (progn
        (add-hook 'post-command-hook #'beady-list--follow nil t)
        (setq beady-list--follow-last nil)
        (beady-list--follow))
    (remove-hook 'post-command-hook #'beady-list--follow t)))

;;;; Filters

(defun beady-list--set-filter (key value)
  "Set KEY of the filter to VALUE and redraw."
  (setq beady-list--filter (plist-put (copy-sequence beady-list--filter) key value))
  (beady-list--render))

(defun beady-list-set-status-filter (preset)
  "Show the beads matching the status PRESET.
PRESET is `open' (not closed), `ready', `blocked', `closed' or `all'."
  (interactive (list (intern (completing-read "Show: " '("open" "ready" "blocked" "closed" "all")
                                              nil t))))
  (beady-list--ensure)
  (beady-list--set-filter :status preset))

(defun beady-list-filter-open ()
  "Show beads that are not closed."
  (interactive)
  (beady-list-set-status-filter 'open))

(defun beady-list-filter-ready ()
  "Show beads that are ready: open with no open blockers."
  (interactive)
  (beady-list-set-status-filter 'ready))

(defun beady-list-filter-blocked ()
  "Show beads that are blocked by status or by an open dependency."
  (interactive)
  (beady-list-set-status-filter 'blocked))

(defun beady-list-filter-closed ()
  "Show closed beads."
  (interactive)
  (beady-list-set-status-filter 'closed))

(defun beady-list-filter-all ()
  "Show beads of every status."
  (interactive)
  (beady-list-set-status-filter 'all))

(defun beady-list--crm-initial (values)
  "Return initial input for `completing-read-multiple' from VALUES."
  (and values (concat (string-join values ",") ",")))

(defun beady-list-filter-statuses (statuses)
  "Show only beads whose status is one of STATUSES (all if empty)."
  (interactive
   (list (completing-read-multiple
          "Statuses (comma separated, empty for all): "
          (beady--ordered-statuses beady-list--statuses) nil t
          (let ((current (plist-get beady-list--filter :status)))
            (and (consp current) (beady-list--crm-initial current))))))
  (beady-list--ensure)
  (beady-list--set-filter :status (or statuses 'all)))

(defun beady-list-filter-types (types)
  "Show only beads whose type is one of TYPES (all if empty)."
  (interactive
   (list (completing-read-multiple
          "Types (empty for all): "
          (delete-dups (append (beady--types beady--root)
                               (delq nil (mapcar (lambda (i) (alist-get 'issue_type i))
                                                 beady-list--issues))))
          nil t (beady-list--crm-initial (plist-get beady-list--filter :types)))))
  (beady-list--ensure)
  (beady-list--set-filter :types types))

(defun beady-list-filter-priorities (priorities)
  "Show only beads whose priority is one of PRIORITIES (all if empty)."
  (interactive
   (list (mapcar (lambda (choice) (string-to-number (substring choice 1 2)))
                 (completing-read-multiple
                  "Priorities (empty for all): "
                  (mapcar (lambda (p) (format "P%d %s" (car p) (cdr p))) beady-priority-names)
                  nil t))))
  (beady-list--ensure)
  (beady-list--set-filter :priorities priorities))

(defun beady-list-filter-labels (labels)
  "Show only beads with at least one of LABELS (all if empty)."
  (interactive
   (list (completing-read-multiple
          "Labels (empty for all): "
          (sort (delete-dups (seq-mapcat (lambda (i) (alist-get 'labels i)) beady-list--issues))
                #'string<)
          nil nil (beady-list--crm-initial (plist-get beady-list--filter :labels)))))
  (beady-list--ensure)
  (beady-list--set-filter :labels labels))

(defun beady-list-filter-assignees (assignees)
  "Show only beads assigned to one of ASSIGNEES (all if empty).
The pseudo assignee \"(unassigned)\" matches beads without assignee."
  (interactive
   (let ((names (sort (delete-dups
                       (delq nil (mapcar (lambda (i)
                                           (let ((a (alist-get 'assignee i)))
                                             (and a (not (string-empty-p a)) a)))
                                         beady-list--issues)))
                      #'string<)))
     (list (mapcar (lambda (a) (if (equal a "(unassigned)") "" a))
                   (completing-read-multiple "Assignees (empty for all): "
                                             (cons "(unassigned)" names) nil t)))))
  (beady-list--ensure)
  (beady-list--set-filter :assignees assignees))

(defun beady-list-filter-parent (parent)
  "Show only PARENT and its descendants (all beads if empty)."
  (interactive
   (list (beady--read-issue "Show beads under (empty for all): "
                            (lambda (issue) (gethash (beady--id issue) beady-list--children)))))
  (beady-list--ensure)
  (beady-list--set-filter :parent (and (not (string-empty-p parent)) parent)))

(defvar beady-list--query-history nil "History of `bd query' expressions.")

(defun beady-list-filter-query (query)
  "Show only beads matching the `bd query' expression QUERY.
For example: priority<=1 AND updated>7d.  An empty QUERY removes the
filter.  When QUERY tests the status, the status filter is set to all
so that it does not hide matches."
  (interactive
   (list (read-string "bd query (e.g. type=bug AND priority<=1; empty to clear): "
                      (plist-get beady-list--filter :query) 'beady-list--query-history)))
  (beady-list--ensure)
  (let ((query (and (not (string-blank-p query)) (string-trim query))))
    (setq beady-list--filter (plist-put (copy-sequence beady-list--filter) :query query))
    (when (and query (string-match-p "\\_<status\\_>" query))
      (setq beady-list--filter (plist-put beady-list--filter :status 'all)))
    (beady-list-refresh)))

(defun beady-list-reset-filters ()
  "Reset the filters to `beady-list-default-filter'."
  (interactive)
  (beady-list--ensure)
  (let ((had-query (plist-get beady-list--filter :query)))
    (setq beady-list--filter (copy-tree beady-list-default-filter))
    (if (or had-query (plist-get beady-list--filter :query))
        (beady-list-refresh)
      (beady-list--render))))

;;;; Search

(defvar beady-list--search-history nil "History of list searches.")

(defun beady-list--read-search ()
  "Read a search string, updating the list as it is typed.
If the minibuffer is aborted, the previous search is restored."
  (let* ((buffer (current-buffer))
         (old (plist-get beady-list--filter :search))
         (timer nil)
         (finished nil)
         (update (lambda (text)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (beady-list--set-filter :search
                                               (and (not (string-blank-p text)) text)))))))
    (unwind-protect
        (prog1
            (minibuffer-with-setup-hook
                (lambda ()
                  (add-hook 'after-change-functions
                            (lambda (&rest _)
                              (let ((text (minibuffer-contents-no-properties)))
                                (when (timerp timer) (cancel-timer timer))
                                (setq timer (run-with-idle-timer
                                             beady-list-search-delay nil update text))))
                            nil t))
              (read-string "Search beads: " old 'beady-list--search-history))
          (setq finished t))
      (when (timerp timer) (cancel-timer timer))
      (unless finished
        (funcall update (or old ""))))))

(defun beady-list-search (text)
  "Show only beads containing every word of TEXT.
The list updates while typing.  The fields searched are listed in
`beady-list-search-fields'.  An empty TEXT clears the search."
  (interactive (progn (beady-list--ensure) (list (beady-list--read-search))))
  (beady-list--ensure)
  (beady-list--set-filter :search (and (not (string-blank-p text)) text)))

(defun beady-list-clear-search ()
  "Clear the search."
  (interactive)
  (beady-list--ensure)
  (beady-list--set-filter :search nil))

;;;; Sorting and grouping commands

(defconst beady-list--sort-fields
  '(priority updated created closed due id title status type assignee)
  "Fields the list can be sorted by.")

(defconst beady-list--group-fields
  '(none status lane priority type assignee label parent)
  "Ways the list can be grouped.")

(defun beady-list-set-sort (field)
  "Sort the list by FIELD."
  (interactive (list (intern (completing-read "Sort by: "
                                              (mapcar #'symbol-name beady-list--sort-fields)
                                              nil t))))
  (beady-list--ensure)
  (setq beady-list--sort field)
  (beady-list--render))

(defun beady-list-toggle-sort-reverse ()
  "Reverse the sort order."
  (interactive)
  (beady-list--ensure)
  (setq beady-list--sort-reverse (not beady-list--sort-reverse))
  (beady-list--render))

(defun beady-list-set-group (group)
  "Group the list by GROUP; nil or `none' removes the grouping."
  (interactive (list (intern (completing-read "Group by: "
                                              (mapcar #'symbol-name beady-list--group-fields)
                                              nil t))))
  (beady-list--ensure)
  (setq beady-list--group (if (eq group 'none) nil group)
        beady-list--collapsed nil)
  (beady-list--render))

(defun beady-list-toggle-tree ()
  "Toggle showing children indented under their parents."
  (interactive)
  (beady-list--ensure)
  (setq beady-list--tree (not beady-list--tree))
  (beady-list--render)
  (message "Tree view %s" (if beady-list--tree "on" "off")))

(defun beady-list-reset-view ()
  "Reset filters, sorting, grouping and tree view to their defaults."
  (interactive)
  (beady-list--ensure)
  (setq beady-list--sort beady-list-default-sort
        beady-list--sort-reverse beady-list-default-sort-reverse
        beady-list--group beady-list-default-group
        beady-list--tree beady-list-default-tree
        beady-list--collapsed nil)
  (beady-list-reset-filters))

(defmacro beady-list--define-sort-command (field)
  "Define a command sorting the list by FIELD."
  `(defun ,(intern (format "beady-list-sort-by-%s" field)) ()
     ,(format "Sort the list by %s." (beady-list--sort-name field))
     (interactive)
     (beady-list-set-sort ',field)))

(beady-list--define-sort-command priority)
(beady-list--define-sort-command updated)
(beady-list--define-sort-command created)
(beady-list--define-sort-command closed)
(beady-list--define-sort-command due)
(beady-list--define-sort-command id)
(beady-list--define-sort-command title)
(beady-list--define-sort-command status)
(beady-list--define-sort-command type)
(beady-list--define-sort-command assignee)

(defmacro beady-list--define-group-command (group)
  "Define a command grouping the list by GROUP."
  `(defun ,(intern (format "beady-list-group-by-%s" group)) ()
     ,(if (eq group 'none)
          "Do not group the list."
        (format "Group the list by %s." (beady-list--group-name group)))
     (interactive)
     (beady-list-set-group ',group)))

(beady-list--define-group-command none)
(beady-list--define-group-command status)
(beady-list--define-group-command lane)
(beady-list--define-group-command priority)
(beady-list--define-group-command type)
(beady-list--define-group-command assignee)
(beady-list--define-group-command label)
(beady-list--define-group-command parent)

;;;; Column profiles and legend

(defun beady-list-toggle-column-profile ()
  "Switch between the compact and wide column layouts."
  (interactive)
  (beady-list--ensure)
  (setq beady-list-columns
        (if (equal beady-list-columns beady-list--columns-wide)
            beady-list--columns-compact
          beady-list--columns-wide))
  (beady-list--render)
  (message "Showing %s columns"
           (if (equal beady-list-columns beady-list--columns-wide) "wide" "compact")))

(defun beady-list--status-legend-entries ()
  "Return the (NAME ICON CATEGORY DESCRIPTION) status entries of the buffer."
  (or (beady--status-info beady--root)
      (let ((statuses (beady--statuses beady--root)))
        (mapcar (lambda (status)
                  (list status (beady--status-icon status)
                        (beady--status-category status statuses) nil))
                (beady--ordered-statuses statuses)))))

(defun beady-list--type-legend-entries ()
  "Return the (TYPE . DESCRIPTION) type entries of the buffer."
  (or (beady--type-info beady--root)
      (mapcar #'list (beady--types beady--root))))

(defun beady-list-show-legend ()
  "Display a legend of the status and type symbols used by the list."
  (interactive)
  (beady-list--ensure)
  (let* ((name (beady--project-name beady--root))
         (status-entries (beady-list--status-legend-entries))
         (type-entries (beady-list--type-legend-entries))
         (buffer (get-buffer-create (format "*beady legend: %s*" name))))
    (with-current-buffer buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Beads legend — %s\n\n" name)
                            'face 'bold))
        (insert (propertize "Statuses\n" 'face 'beady-section-heading))
        (dolist (entry status-entries)
          (let* ((status (nth 0 entry))
                 (icon (beady--status-icon status))
                 (label (beady--status-label status))
                 (description (nth 3 entry))
                 (face (beady--status-face status)))
            (insert "  " (propertize icon 'face face) " "
                    (propertize (string-pad label 10) 'face face)
                    (if (equal label status) "" (format "(%s) " status))
                    (or description "")
                    "\n")))
        (insert (format "  %s %-10s%s\n"
                        (propertize beady-blocked-indicator 'face 'beady-status-blocked)
                        "" "blocked by an open dependency"))
        (insert "\n" (propertize "Types\n" 'face 'beady-section-heading))
        (dolist (entry type-entries)
          (insert (format "  %-12s %s\n" (car entry) (or (cdr entry) ""))))
        (goto-char (point-min))))
    (display-buffer buffer beady-display-buffer-action)))

;;;; Transient menus

(defun beady-list--choice (label active)
  "Return LABEL for a menu entry, highlighted if ACTIVE."
  (if active (propertize label 'face 'transient-value) label))

(defun beady-list--value (label value)
  "Return LABEL followed by VALUE, or by \"any\" if VALUE is nil."
  (concat label " "
          (if value
              (propertize (truncate-string-to-width value 30 nil nil "…")
                          'face 'transient-value)
            (propertize "any" 'face 'transient-inactive-value))))

(defun beady-list--status-choice (label preset)
  "Return the menu LABEL of status PRESET."
  (beady-list--choice label (eq (plist-get beady-list--filter :status) preset)))

(defun beady-list--sort-choice (label field)
  "Return the menu LABEL of sort FIELD."
  (beady-list--choice label (eq beady-list--sort field)))

(defun beady-list--group-choice (label group)
  "Return the menu LABEL of GROUP."
  (beady-list--choice label (eq beady-list--group group)))

(defun beady-list--filter-value (key)
  "Return a description of filter KEY's value, or nil."
  (let ((value (plist-get beady-list--filter key)))
    (pcase key
      (:status (and (consp value) (string-join value ",")))
      (:priorities (and value (mapconcat (lambda (p) (format "P%d" p)) value ",")))
      (:assignees (and value (mapconcat (lambda (a) (if (string-empty-p a) "unassigned" a))
                                        value ",")))
      ((or :types :labels) (and value (string-join value ",")))
      (_ value))))

(defun beady-list--view-heading ()
  "Return the heading of `beady-list-view-menu'."
  (concat (propertize "View " 'face 'transient-heading)
          (propertize (beady--project-name beady--root) 'face 'bold)
          (propertize (format "  %d of %d beads shown"
                              (length beady-list--displayed)
                              (length beady-list--issues))
                      'face 'transient-inactive-value)))

(transient-define-prefix beady-list-view-menu ()
  "Search, filter, sort and group the beads list.
Every choice applies immediately; the menu stays open until you
press q or \\[keyboard-quit]."
  :transient-suffix 'transient--do-stay
  [:description beady-list--view-heading
   ["Search"
    ("/" beady-list-search
     :description (lambda () (beady-list--value "Text" (plist-get beady-list--filter :search))))
    ("Q" beady-list-filter-query
     :description (lambda () (beady-list--value "bd query" (plist-get beady-list--filter :query))))]
   ["Show"
    ("o" beady-list-filter-open :description (lambda () (beady-list--status-choice "Open (not closed)" 'open)))
    ("r" beady-list-filter-ready :description (lambda () (beady-list--status-choice "Ready to work" 'ready)))
    ("b" beady-list-filter-blocked :description (lambda () (beady-list--status-choice "Blocked" 'blocked)))
    ("c" beady-list-filter-closed :description (lambda () (beady-list--status-choice "Closed" 'closed)))
    ("a" beady-list-filter-all :description (lambda () (beady-list--status-choice "All" 'all)))]
   ["Filter by"
    ("fs" beady-list-filter-statuses
     :description (lambda () (beady-list--value "Status" (beady-list--filter-value :status))))
    ("ft" beady-list-filter-types
     :description (lambda () (beady-list--value "Type" (beady-list--filter-value :types))))
    ("fp" beady-list-filter-priorities
     :description (lambda () (beady-list--value "Priority" (beady-list--filter-value :priorities))))
    ("fl" beady-list-filter-labels
     :description (lambda () (beady-list--value "Label" (beady-list--filter-value :labels))))
    ("fa" beady-list-filter-assignees
     :description (lambda () (beady-list--value "Assignee" (beady-list--filter-value :assignees))))
    ("fe" beady-list-filter-parent
     :description (lambda () (beady-list--value "Epic/parent" (beady-list--filter-value :parent))))
    ("fx" "Reset filters" beady-list-reset-filters)]]
  [["Sort by"
    ("sp" beady-list-sort-by-priority :description (lambda () (beady-list--sort-choice "Priority" 'priority)))
    ("su" beady-list-sort-by-updated :description (lambda () (beady-list--sort-choice "Last update" 'updated)))
    ("sc" beady-list-sort-by-created :description (lambda () (beady-list--sort-choice "Creation" 'created)))
    ("sC" beady-list-sort-by-closed :description (lambda () (beady-list--sort-choice "Close date" 'closed)))
    ("sd" beady-list-sort-by-due :description (lambda () (beady-list--sort-choice "Due date" 'due)))]
   [""
    ("si" beady-list-sort-by-id :description (lambda () (beady-list--sort-choice "ID" 'id)))
    ("st" beady-list-sort-by-title :description (lambda () (beady-list--sort-choice "Title" 'title)))
    ("ss" beady-list-sort-by-status :description (lambda () (beady-list--sort-choice "Status" 'status)))
    ("sT" beady-list-sort-by-type :description (lambda () (beady-list--sort-choice "Type" 'type)))
    ("sa" beady-list-sort-by-assignee :description (lambda () (beady-list--sort-choice "Assignee" 'assignee)))
    ("sr" beady-list-toggle-sort-reverse
     :description (lambda () (beady-list--choice "Reverse order" beady-list--sort-reverse)))]
   ["Group by"
    ("gn" beady-list-group-by-none :description (lambda () (beady-list--group-choice "Nothing" nil)))
    ("gs" beady-list-group-by-status :description (lambda () (beady-list--group-choice "Status" 'status)))
    ("gb" beady-list-group-by-lane :description (lambda () (beady-list--group-choice "Board lanes" 'lane)))
    ("gp" beady-list-group-by-priority :description (lambda () (beady-list--group-choice "Priority" 'priority)))]
   [""
    ("gt" beady-list-group-by-type :description (lambda () (beady-list--group-choice "Type" 'type)))
    ("ga" beady-list-group-by-assignee :description (lambda () (beady-list--group-choice "Assignee" 'assignee)))
    ("gl" beady-list-group-by-label :description (lambda () (beady-list--group-choice "Label" 'label)))
    ("ge" beady-list-group-by-parent :description (lambda () (beady-list--group-choice "Epic/parent" 'parent)))]
   ["Display"
    ("T" beady-list-toggle-tree :description (lambda () (beady-list--choice "Tree of children" beady-list--tree)))
    ("F" beady-list-follow-mode
     :description (lambda () (beady-list--choice "Follow point" beady-list-follow-mode)))
    ("W" beady-list-toggle-column-profile
     :description (lambda () (beady-list--choice "Wide columns" (equal beady-list-columns beady-list--columns-wide))))
    ("h" "Legend of icons" beady-list-show-legend)
    ("R" "Reset everything" beady-list-reset-view)
    ("q" "Done" transient-quit-one)]]
  (interactive)
  (beady-list--ensure)
  (transient-setup 'beady-list-view-menu))

(defmacro beady-list--define-dispatch (name refresh-key open-key display-key)
  "Define a command dispatch transient called NAME.
REFRESH-KEY, OPEN-KEY and DISPLAY-KEY are the keys advertised for
refreshing the list, opening the bead at point in another window and
displaying it there."
  `(transient-define-prefix ,name ()
     "Show all commands of the beads list."
     [:description (lambda () (concat (propertize "Beads " 'face 'transient-heading)
                                      (propertize (beady--project-name beady--root) 'face 'bold)))
      ["View"
       ("v" "Filter, sort, group…" beady-list-view-menu)
       ("/" "Search" beady-list-search)
       ("T" "Toggle tree" beady-list-toggle-tree)
       ("F" "Toggle follow mode" beady-list-follow-mode)
       ("TAB" "Fold group" beady-list-toggle-group)
       (,refresh-key "Refresh" beady-list-refresh)]
      ["Open"
       ("RET" "Show bead" beady-list-show)
       (,open-key "Show in other window" beady-list-show-other-window)
       (,display-key "Display in other window" beady-list-display)]
      ["Change (bead at point or marked)"
       ("s" "Status…" beady-status-menu)
       ("x" "Close…" beady-close)
       ("P" "Priority…" beady-priority-menu)
       ("a" "Assign…" beady-assign)
       ("L" "Labels…" beady-labels-menu)
       ("e" "Edit…" beady-edit-menu)
       ("C" "Comment…" beady-add-comment)]
      ["Marks"
       ("m" "Mark" beady-list-mark)
       ("u" "Unmark" beady-list-unmark)
       ("U" "Unmark all" beady-list-unmark-all)
       ("t" "Toggle all marks" beady-list-toggle-marks)]
      ["Other"
       ("c" "Create a bead…" beady-create-menu)
       ("S" "Sync & remotes…" beady-sync-menu)
       ("w" "Copy ID" beady-copy-id)
       ("W" "Wide/compact columns" beady-list-toggle-column-profile)
       ("h" "Legend of icons" beady-list-show-legend)]]
     (interactive)
     (beady-list--ensure)
     (transient-setup ',name)))

(beady-list--define-dispatch beady-list--dispatch "g" "o" "C-o")
(beady-list--define-dispatch beady-list--dispatch-evil "gr" "go" "gO")

(defun beady-list-dispatch ()
  "Show all commands of the beads list.
The menu uses the key bindings of the active editing state."
  (interactive)
  (beady-list--ensure)
  (transient-setup (if (eq (key-binding (kbd "go")) 'beady-list-show-other-window)
                       'beady-list--dispatch-evil
                     'beady-list--dispatch)))

;;;; Auto refresh

(defvar beady-list--auto-refresh-timer nil "Timer refreshing list buffers.")

(defun beady-list--auto-refresh ()
  "Refresh visible, idle list buffers."
  (let ((buffers (seq-filter (lambda (b) (eq (buffer-local-value 'major-mode b) 'beady-list-mode))
                             (buffer-list))))
    (if (or (null buffers) (null beady-list-auto-refresh-interval))
        (progn (cancel-timer beady-list--auto-refresh-timer)
               (setq beady-list--auto-refresh-timer nil))
      (unless (or (active-minibuffer-window)
                  (bound-and-true-p transient--prefix))
        (dolist (buffer buffers)
          (when (get-buffer-window buffer 'visible)
            (with-current-buffer buffer
              (unless (beady-list--loading-p)
                (beady-list-refresh)))))))))

(defun beady-list--start-auto-refresh ()
  "Start the auto refresh timer if `beady-list-auto-refresh-interval' is set."
  (when (and beady-list-auto-refresh-interval (not beady-list--auto-refresh-timer))
    (setq beady-list--auto-refresh-timer
          (run-with-timer beady-list-auto-refresh-interval
                          beady-list-auto-refresh-interval
                          #'beady-list--auto-refresh))))

;;;; Mode

(defvar-keymap beady-list-mode-map
  :doc "Keymap for `beady-list-mode'."
  :parent special-mode-map
  "RET" #'beady-list-show
  "o" #'beady-list-show-other-window
  "C-o" #'beady-list-display
  "n" #'beady-list-next
  "p" #'beady-list-previous
  "M-n" #'beady-list-next-group
  "M-p" #'beady-list-previous-group
  "TAB" #'beady-list-toggle-group
  "<backtab>" #'beady-list-toggle-all-groups
  "g" #'beady-list-refresh
  "v" #'beady-list-view-menu
  "/" #'beady-list-search
  "?" #'beady-list-dispatch
  "T" #'beady-list-toggle-tree
  "F" #'beady-list-follow-mode
  "m" #'beady-list-mark
  "u" #'beady-list-unmark
  "U" #'beady-list-unmark-all
  "t" #'beady-list-toggle-marks
  "s" #'beady-status-menu
  "x" #'beady-close
  "P" #'beady-priority-menu
  "a" #'beady-assign
  "L" #'beady-labels-menu
  "C" #'beady-add-comment
  "e" #'beady-edit-menu
  "c" #'beady-create-menu
  "S" #'beady-sync-menu
  "w" #'beady-copy-id)

(define-derived-mode beady-list-mode special-mode "Beady"
  "Major mode for browsing the beads of a project.

Press \\[beady-list-dispatch] to see all commands and \\[beady-list-view-menu]
to search, filter, sort and group the list.  Commands that change beads
act on the marked beads, the beads in the region or the bead at point.

\\{beady-list-mode-map}"
  (setq-local revert-buffer-function #'beady-list-refresh)
  (setq-local beady--refresh-function #'beady-list-refresh)
  (setq-local beady--targets-function #'beady-list--targets)
  (setq-local beady--lookup-function
              (lambda (id) (and beady-list--table (gethash id beady-list--table))))
  (setq-local beady--issues-function (lambda () beady-list--issues))
  (setq-local beady--focus-function (lambda (id) (setq beady-list--focus id)))
  (setq beady-list--filter (copy-tree beady-list-default-filter)
        beady-list--sort beady-list-default-sort
        beady-list--sort-reverse beady-list-default-sort-reverse
        beady-list--group beady-list-default-group
        beady-list--tree beady-list-default-tree
        beady-list--marks (make-hash-table :test #'equal))
  (setq-local truncate-lines t)
  (setq-local buffer-read-only t)
  (setq header-line-format '(:eval (beady-list--header-line)))
  (header-line-indent-mode 1)
  (when beady-list-highlight-current-line
    (hl-line-mode 1))
  (add-hook 'kill-buffer-hook #'beady-list--cancel nil t)
  (beady-list--start-auto-refresh)
  (beady--maybe-setup-evil))

(defun beady-list--get-buffer (root)
  "Return the list buffer of the project at ROOT, creating it if needed."
  (or (car (beady--buffers root 'beady-list-mode))
      (let ((buffer (generate-new-buffer (format "*beady: %s*" (beady--project-name root)))))
        (with-current-buffer buffer
          (beady-list-mode)
          (setq default-directory root)
          (setq beady--root root)
          (beady-list--render))
        buffer)))

;;;###autoload
(defun beady-list (&optional root)
  "Show the beads of the project at ROOT.
ROOT defaults to the project containing `default-directory'."
  (interactive)
  (let* ((root (or root (beady--current-root)))
         (buffer (beady-list--get-buffer root)))
    (with-current-buffer buffer
      (beady-list-refresh))
    (pop-to-buffer buffer beady-display-buffer-action)
    buffer))

(provide 'beady-list)
;;; beady-list.el ends here
