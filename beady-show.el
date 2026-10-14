;;; beady-show.el --- View a single bead  -*- lexical-binding: t; -*-

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

;; `beady-show-mode' displays one bead: its fields, long text sections
;; (rendered as Markdown when markdown-mode is available), relations to
;; other beads and comments.  Related bead IDs are buttons; following
;; them keeps a back/forward history like `help-mode'.
;;
;; The view is drawn immediately from data already loaded by a list
;; buffer, then completed asynchronously with `bd show'.

;;; Code:

(require 'beady-core)
(require 'beady-actions)
(require 'button)
(require 'text-property-search)

(declare-function gfm-mode "markdown-mode" ())
(declare-function beady-list-neighbor-id "beady-list" (buffer id n))
(declare-function beady-list-goto-id "beady-list" (id))
(declare-function beady-list "beady-list" (&optional root))

(defcustom beady-show-reuse-buffer t
  "When non-nil, show all beads of a project in a single buffer.
Navigation history is kept with `beady-show-back' and
`beady-show-forward'.  When nil, each bead gets its own buffer."
  :type 'boolean
  :group 'beady)

(defcustom beady-show-fontify-markdown t
  "When non-nil, fontify descriptions and comments as Markdown.
This requires the markdown-mode package."
  :type 'boolean
  :group 'beady)

(defcustom beady-show-header-hints t
  "When non-nil, show key hints in the header line of bead buffers."
  :type 'boolean
  :group 'beady)

;;;; State

(defvar-local beady-show--id nil "ID of the bead shown in this buffer.")
(defvar-local beady-show--issue nil "Data of the bead shown in this buffer.")
(defvar-local beady-show--complete nil
  "Non-nil when `beady-show--issue' comes from `bd show'.")
(defvar-local beady-show--error nil "Error message of the last fetch.")
(defvar-local beady-show--process nil "Process fetching the bead.")
(defvar-local beady-show--history nil "IDs to go back to.")
(defvar-local beady-show--forward nil "IDs to go forward to.")
(defvar-local beady-show--list-buffer nil "List buffer this view was opened from.")
(defvar-local beady-show--hint-cache nil "Cons of (STATE . HINTS) for the header.")

;;;; Buttons

(define-button-type 'beady-issue
  'action #'beady-show--follow-button
  'follow-link t
  'face 'beady-id
  'help-echo "mouse-1, RET: view this bead")

(defun beady-show--follow-button (button)
  "Show the bead referenced by BUTTON."
  (beady-show-issue (button-get button 'beady-id)))

(defun beady-show--insert-id-button (id)
  "Insert a button showing bead ID."
  (insert-text-button id 'type 'beady-issue 'beady-id id))

;;;; Displaying beads

(defun beady-show--get-buffer (root id)
  "Return the buffer used to show bead ID of project ROOT."
  (or (seq-find (lambda (buf)
                  (or beady-show-reuse-buffer
                      (equal (buffer-local-value 'beady-show--id buf) id)))
                (beady--buffers root 'beady-show-mode))
      (let ((buffer (generate-new-buffer
                     (if beady-show-reuse-buffer
                         (format "*beady-show: %s*" (beady--project-name root))
                       (format "*beady-show: %s*" id)))))
        (with-current-buffer buffer
          (beady-show-mode)
          (setq default-directory root)
          (setq beady--root root))
        buffer)))

(defun beady-show-issue (id &optional root action no-select)
  "Show bead ID of the project at ROOT.
ACTION is a `display-buffer' action, defaulting to the same window.
With NO-SELECT, display the buffer without selecting it."
  (interactive (list (beady--read-issue "Show bead: ")))
  (when (string-empty-p id) (user-error "No bead given"))
  (let* ((root (or root (beady--current-root)))
         (from (current-buffer))
         (buffer (beady-show--get-buffer root id)))
    (with-current-buffer buffer
      (unless (eq from buffer)
        (pcase (buffer-local-value 'major-mode from)
          ('beady-list-mode (setq beady-show--list-buffer from))
          ('beady-show-mode
           ;; Following a link into another bead buffer: carry the history.
           (unless beady-show--id
             (with-current-buffer from
               (let ((history (cons beady-show--id beady-show--history))
                     (list beady-show--list-buffer))
                 (with-current-buffer buffer
                   (setq beady-show--history history
                         beady-show--list-buffer list))))))))
      (unless (equal id beady-show--id)
        (when beady-show--id
          (push beady-show--id beady-show--history)
          (setq beady-show--forward nil))
        (beady-show--set-id id))
      (beady-show-refresh))
    (unless (eq from buffer)
      (let ((action (or action beady-display-buffer-action)))
        (if no-select
            (display-buffer buffer action)
          (pop-to-buffer buffer action))))
    buffer))

(defun beady-show--set-id (id)
  "Make the current buffer show ID, drawing what is already known."
  (setq beady-show--id id
        beady-show--error nil
        beady-show--complete nil
        beady-show--issue (beady--lookup-issue id beady--root))
  (beady-show--render t))

(defun beady-show-refresh (&rest _)
  "Fetch the bead shown in the current buffer again and redraw it."
  (interactive)
  (unless (derived-mode-p 'beady-show-mode)
    (user-error "Not in a bead buffer"))
  (let ((buffer (current-buffer))
        (id beady-show--id))
    (beady--cancel-process beady-show--process)
    (setq mode-line-process '(:propertize " loading…" face beady-dim))
    (cl-flet ((finish (issue error)
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (when (equal id beady-show--id)
                      (setq beady-show--process nil
                            mode-line-process nil
                            beady-show--error error)
                      (when issue
                        (setq beady-show--issue issue
                              beady-show--complete t))
                      (beady-show--render))))))
      (setq beady-show--process
            (beady--run-async
             (list "--json" "show" id "--include-comments" "--include-dependents")
             (lambda (output)
               (let ((issue (car-safe (ignore-errors (beady--parse-json output)))))
                 (if (and issue (consp (car-safe issue)))
                     (finish issue nil)
                   (finish nil (format "Could not read the data of %s" id)))))
             (lambda (msg) (finish nil msg)))))))

;;;; Rendering

(defun beady-show--render (&optional reset-point)
  "Redraw the current bead buffer.
With RESET-POINT, move to the top instead of keeping the position."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (column (current-column))
        (windows (mapcar (lambda (w) (cons w (count-lines (window-start w) (window-point w))))
                         (get-buffer-window-list nil nil t))))
    (erase-buffer)
    (cond
     ((and beady-show--error (not beady-show--issue))
      (insert (propertize (or beady-show--id "") 'face 'beady-id) "\n\n"
              (propertize beady-show--error 'face 'error) "\n\n"
              (substitute-command-keys "Press \\[beady-show-refresh] to try again.\n")))
     ((not beady-show--issue)
      (insert (propertize (format "Loading %s…" beady-show--id) 'face 'beady-dim) "\n"))
     (t (beady-show--insert-issue beady-show--issue)))
    (setq beady-show--hint-cache nil)
    (if reset-point
        (goto-char (point-min))
      (goto-char (point-min))
      (forward-line (1- line))
      (move-to-column column)
      (dolist (entry windows)
        (when (window-live-p (car entry))
          (set-window-point (car entry) (point))
          (beady--restore-window-start (car entry) (cdr entry)))))))

(defun beady-show--fontify (text)
  "Return TEXT fontified as Markdown when possible."
  (if (and beady-show-fontify-markdown
           (or (fboundp 'gfm-mode) (require 'markdown-mode nil t)))
      (condition-case nil
          (with-temp-buffer
            (insert text)
            (delay-mode-hooks (gfm-mode))
            (font-lock-ensure)
            (beady-show--faces-only (buffer-string)))
        (error text))
    text))

(defun beady-show--faces-only (string)
  "Return a copy of STRING that keeps only its faces."
  (let ((result (substring-no-properties string))
        (pos 0)
        (len (length string)))
    (while (< pos len)
      (let ((next (or (next-single-property-change pos 'face string)
                      len))
            (face (get-text-property pos 'face string)))
        (when face
          (put-text-property pos next 'face face result))
        (setq pos next)))
    result))

(defun beady-show--insert-text (text)
  "Insert TEXT indented, as Markdown when possible."
  (let ((start (point)))
    (insert (beady-show--fontify (string-trim-right text)) "\n")
    (add-text-properties start (point) '(line-prefix "  " wrap-prefix "  "))))

(defun beady-show--heading (title &optional count)
  "Insert a section heading TITLE with an optional COUNT."
  (insert "\n"
          (propertize title 'face 'beady-section-heading 'beady-section t)
          (if count (propertize (format " (%d)" count) 'face 'beady-dim) "")
          "\n"))

(defun beady-show--field (name value)
  "Insert a field called NAME with VALUE, unless VALUE is empty."
  (when (and value (not (equal value "")))
    (insert (propertize (string-pad name 12) 'face 'beady-field-name) " " value "\n")))

(defun beady-show--date (string &optional suffix)
  "Format the timestamp STRING with its age, followed by SUFFIX."
  (when-let* ((time (beady--time string)))
    (concat (beady--format-date time)
            (propertize (format "  (%s)" (let ((age (beady--format-age time)))
                                           (if (or (equal age "now")
                                                   (string-prefix-p "in " age))
                                               age
                                             (concat age " ago"))))
                        'face 'beady-date)
            (or suffix ""))))

(defun beady-show--progress (closed total)
  "Return a progress bar for CLOSED out of TOTAL children."
  (let* ((width 20)
         (filled (if (> total 0) (round (* width (/ (float closed) total))) 0)))
    (concat (propertize (make-string filled ?█) 'face 'success)
            (propertize (make-string (- width filled) ?░) 'face 'beady-dim)
            (format "  %d of %d closed" closed total))))

(defun beady-show--dep-type (dep)
  "Return the dependency type of DEP, which may come from list or show data."
  (or (alist-get 'dependency_type dep) (alist-get 'type dep)))

(defun beady-show--dep-id (dep)
  "Return the ID of the other bead in DEP."
  (or (alist-get 'depends_on_id dep) (alist-get 'id dep)))

(defun beady-show--relations (issue)
  "Return an alist of relation kinds to lists of related beads of ISSUE.
Each related bead is a cons (DEPENDENCY-TYPE . DATA)."
  (let (parent children depends blocks related)
    (dolist (dep (alist-get 'dependencies issue))
      (let ((type (beady-show--dep-type dep)))
        (cond ((equal type "parent-child") (push (cons type dep) parent))
              ((member type '("blocks" "conditional-blocks" "waits-for"))
               (push (cons type dep) depends))
              (t (push (cons type dep) related)))))
    (dolist (dep (alist-get 'dependents issue))
      (let ((type (beady-show--dep-type dep)))
        (cond ((equal type "parent-child") (push (cons type dep) children))
              ((member type '("blocks" "conditional-blocks" "waits-for"))
               (push (cons type dep) blocks))
              (t (push (cons type dep) related)))))
    (setq children (sort children (lambda (a b)
                                    (string-version-lessp (beady-show--dep-id (cdr a))
                                                          (beady-show--dep-id (cdr b))))))
    `((parent . ,(nreverse parent)) (children . ,children)
      (depends . ,(nreverse depends)) (blocks . ,(nreverse blocks))
      (related . ,(nreverse related)))))

(defun beady-show--insert-relation (arrow entry)
  "Insert a line for the related bead ENTRY, prefixed with ARROW."
  (let* ((type (car entry))
         (dep (cdr entry))
         (id (beady-show--dep-id dep))
         (known (if (alist-get 'title dep) dep (beady--lookup-issue id beady--root)))
         (status (alist-get 'status known)))
    (insert "  " (propertize arrow 'face 'beady-dim) " "
            (if status
                (propertize (beady--status-icon status) 'face (beady--status-face status))
              " ")
            " ")
    (beady-show--insert-id-button id)
    (when known
      (insert "  " (beady--format-priority (alist-get 'priority known))
              "  " (propertize (or (alist-get 'title known) "")
                               'face (if (equal status "closed") 'beady-closed 'beady-title))))
    (unless (member type '("parent-child" "blocks"))
      (insert "  " (propertize (format "[%s]" type) 'face 'beady-dim)))
    (insert "\n")))

(defun beady-show--open-blockers (issue)
  "Return the IDs of open beads blocking ISSUE, when known."
  (let ((statuses (beady--statuses beady--root)))
    (cl-loop for dep in (alist-get 'dependencies issue)
             for type = (beady-show--dep-type dep)
             for id = (beady-show--dep-id dep)
             for known = (if (alist-get 'status dep) dep (beady--lookup-issue id beady--root))
             for status = (alist-get 'status known)
             when (and (member type '("blocks" "conditional-blocks" "waits-for"))
                       (not (and status (beady--status-done-p status statuses))))
             collect id)))

(defun beady-show--format-estimate (minutes)
  "Format MINUTES as hours and minutes."
  (when (and (numberp minutes) (> minutes 0))
    (let ((h (/ minutes 60)) (m (% minutes 60)))
      (string-trim (concat (if (> h 0) (format "%dh " h) "")
                           (if (> m 0) (format "%dm" m) ""))))))

(defun beady-show--insert-issue (issue)
  "Insert the contents of ISSUE into the current buffer."
  (let-alist issue
    (let ((blockers (beady-show--open-blockers issue))
          (relations (beady-show--relations issue)))
      ;; Title
      (insert (propertize (beady--status-icon .status) 'face (beady--status-face .status))
              " " (propertize .id 'face 'beady-id) "  "
              (propertize (or .title "") 'face 'beady-heading) "\n\n")
      ;; Fields
      (beady-show--field
       "Status"
       (concat (beady--format-status .status)
               (when blockers
                 (concat "  " (propertize (concat beady-blocked-indicator " blocked by ")
                                          'face 'beady-blocked)
                         (string-join blockers ", ")))))
      (beady-show--field "Priority"
                         (concat (beady--format-priority .priority) " "
                                 (beady--priority-name .priority)))
      (beady-show--field "Type" (beady--format-type .issue_type))
      (beady-show--field "Assignee"
                         (if (and .assignee (not (string-empty-p .assignee)))
                             (beady--format-assignee .assignee)
                           (propertize "unassigned" 'face 'beady-dim)))
      (beady-show--field "Owner" .owner)
      (beady-show--field "Labels" (and .labels (beady--format-labels .labels)))
      (when (and .epic_total_children (> .epic_total_children 0))
        (beady-show--field "Progress" (beady-show--progress (or .epic_closed_children 0)
                                                            .epic_total_children)))
      (beady-show--field "Created" (beady-show--date .created_at
                                                     (and .created_by
                                                          (concat "  by " .created_by))))
      (beady-show--field "Updated" (beady-show--date .updated_at))
      (beady-show--field "Started" (beady-show--date .started_at))
      (beady-show--field "Closed" (beady-show--date .closed_at))
      (beady-show--field "Due" (beady-show--date .due_at))
      (beady-show--field "Deferred" (beady-show--date .defer_until))
      (beady-show--field "Estimate" (beady-show--format-estimate .estimated_minutes))
      (beady-show--field "External" .external_ref)
      (beady-show--field "Spec" .spec_id)
      ;; Text sections
      (dolist (section `(("Description" . ,.description)
                         ("Design" . ,.design)
                         ("Acceptance criteria" . ,.acceptance_criteria)
                         ("Notes" . ,.notes)
                         ("Close reason" . ,.close_reason)))
        (when (and (cdr section) (not (string-blank-p (cdr section))))
          (beady-show--heading (car section))
          (beady-show--insert-text (cdr section))))
      ;; Relations
      (pcase-dolist (`(,kind ,title ,arrow)
                     '((parent "Parent" "↑") (children "Children" "↓")
                       (depends "Depends on" "→") (blocks "Blocks" "←")
                       (related "Related" "↔")))
        (when-let* ((entries (alist-get kind relations)))
          (beady-show--heading title (and (cdr entries) (length entries)))
          (dolist (entry entries)
            (beady-show--insert-relation arrow entry))))
      ;; Comments
      (cond
       (.comments
        (beady-show--heading "Comments" (length .comments))
        (dolist (comment .comments)
          (let-alist comment
            (insert "  " (propertize (or .author "?") 'face 'beady-assignee)
                    (propertize (concat "  " (or (beady-show--date .created_at) ""))
                                'face 'beady-date)
                    "\n")
            (let ((start (point)))
              (beady-show--insert-text (or .text ""))
              (add-text-properties start (point) '(line-prefix "    " wrap-prefix "    "))))))
       ((and .comment_count (> .comment_count 0) (not beady-show--complete))
        (beady-show--heading "Comments" .comment_count)
        (insert (propertize "  Loading…\n" 'face 'beady-dim))))
      (when beady-show--error
        (insert "\n" (propertize beady-show--error 'face 'error) "\n")))))

;;;; Header line

(defun beady-show--header-line ()
  "Return the header line of a bead buffer."
  (let ((state (bound-and-true-p evil-state)))
    (unless (and beady-show--hint-cache (equal (car beady-show--hint-cache) state))
      (setq beady-show--hint-cache
            (cons state
                  (beady--hints '((beady-show-back . "back")
                                  (beady-show-forward . "forward")
                                  (beady-status-menu . "status")
                                  (beady-edit-menu . "edit")
                                  (beady-add-comment . "comment")
                                  (beady-show-dispatch . "all commands"))))))
    (concat (propertize (or beady-show--id "") 'face 'beady-id)
            (if beady-show-header-hints
                (concat "   " (cdr beady-show--hint-cache))
              ""))))

;;;; Commands

(defun beady-show--lookup (id)
  "Return the data of ID if it is the bead shown in this buffer."
  (and (equal id beady-show--id) beady-show--issue))

(defun beady-show-back ()
  "Go back to the previously shown bead."
  (interactive)
  (unless beady-show--history (user-error "No previous bead"))
  (push beady-show--id beady-show--forward)
  (beady-show--set-id (pop beady-show--history))
  (beady-show-refresh))

(defun beady-show-forward ()
  "Go forward to the next bead in the history."
  (interactive)
  (unless beady-show--forward (user-error "No next bead"))
  (push beady-show--id beady-show--history)
  (beady-show--set-id (pop beady-show--forward))
  (beady-show-refresh))

(defun beady-show--list-buffer ()
  "Return the list buffer associated with the current bead buffer."
  (or (and (buffer-live-p beady-show--list-buffer) beady-show--list-buffer)
      (car (beady--buffers beady--root 'beady-list-mode))))

(defun beady-show--step (n)
  "Show the bead N positions away in the associated list buffer."
  (let* ((list (or (beady-show--list-buffer)
                   (user-error "No beads list for this project")))
         (id (or (beady-list-neighbor-id list beady-show--id n)
                 (user-error "No %s bead in the list" (if (> n 0) "next" "previous")))))
    (with-current-buffer list
      (beady-list-goto-id id))
    (beady-show-issue id)))

(defun beady-show-next ()
  "Show the next bead of the list this view was opened from."
  (interactive)
  (beady-show--step 1))

(defun beady-show-previous ()
  "Show the previous bead of the list this view was opened from."
  (interactive)
  (beady-show--step -1))

(defun beady-show-parent ()
  "Show the parent of the current bead."
  (interactive)
  (beady-show-issue (or (and beady-show--issue (beady--issue-parent beady-show--issue))
                        (user-error "%s has no parent" beady-show--id))))

(defun beady-show-goto-list ()
  "Switch to the beads list with point on the current bead."
  (interactive)
  (let ((id beady-show--id)
        (list (beady-show--list-buffer)))
    (if (not list)
        (beady-list beady--root)
      (pop-to-buffer list beady-display-buffer-action)
      (beady-list-goto-id id))))

(defun beady-show-next-section (&optional n)
  "Move to the next section heading, or the Nth next."
  (interactive "p")
  (let ((n (or n 1)))
    (dotimes (_ (abs n))
      (let ((match (save-excursion
                     (if (> n 0)
                         (progn (end-of-line)
                                (text-property-search-forward 'beady-section t t))
                       (beginning-of-line)
                       (text-property-search-backward 'beady-section t t)))))
        (if match
            (goto-char (prop-match-beginning match))
          (user-error "No more sections"))))))

(defun beady-show-previous-section (&optional n)
  "Move to the previous section heading, or the Nth previous."
  (interactive "p")
  (beady-show-next-section (- (or n 1))))

(transient-define-prefix beady-show-dispatch ()
  "Show the commands available in a bead buffer."
  [:description (lambda () (concat (propertize "Bead " 'face 'transient-heading)
                                   (propertize (or beady-show--id "") 'face 'beady-id)))
   ["Navigate"
    ("RET" "Follow link at point" push-button)
    ("l" "Back" beady-show-back)
    ("r" "Forward" beady-show-forward)
    ("n" "Next bead in list" beady-show-next)
    ("p" "Previous bead in list" beady-show-previous)
    ("^" "Parent" beady-show-parent)
    ("j" "Jump to the list" beady-show-goto-list)]
   ["Change"
    ("s" "Status…" beady-status-menu)
    ("x" "Close…" beady-close)
    ("P" "Priority…" beady-priority-menu)
    ("a" "Assign…" beady-assign)
    ("L" "Labels…" beady-labels-menu)
    ("e" "Edit…" beady-edit-menu)
    ("C" "Comment…" beady-add-comment)]
   ["Other"
    ("c" "Create a bead…" beady-create-menu)
    ("w" "Copy ID" beady-copy-id)
    ("g" "Refresh" beady-show-refresh)]])

;;;; Mode

(defvar-keymap beady-show-mode-map
  :doc "Keymap for `beady-show-mode'."
  :parent special-mode-map
  "RET" #'push-button
  "TAB" #'forward-button
  "<backtab>" #'backward-button
  "l" #'beady-show-back
  "r" #'beady-show-forward
  "n" #'beady-show-next
  "p" #'beady-show-previous
  "^" #'beady-show-parent
  "j" #'beady-show-goto-list
  "M-n" #'beady-show-next-section
  "M-p" #'beady-show-previous-section
  "g" #'beady-show-refresh
  "?" #'beady-show-dispatch
  "s" #'beady-status-menu
  "x" #'beady-close
  "P" #'beady-priority-menu
  "a" #'beady-assign
  "L" #'beady-labels-menu
  "e" #'beady-edit-menu
  "C" #'beady-add-comment
  "c" #'beady-create-menu
  "w" #'beady-copy-id)

(define-derived-mode beady-show-mode special-mode "Beady-Show"
  "Major mode for viewing a single bead.

Bead IDs are buttons: \\[push-button] follows the one at point and
\\[beady-show-back] / \\[beady-show-forward] move through the history.
Press \\[beady-show-dispatch] for a menu of all commands.

\\{beady-show-mode-map}"
  (setq-local revert-buffer-function #'beady-show-refresh)
  (setq-local beady--refresh-function #'beady-show-refresh)
  (setq-local beady--targets-function
              (lambda () (and beady-show--id (list beady-show--id))))
  (setq-local beady--lookup-function #'beady-show--lookup)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq header-line-format '(:eval (beady-show--header-line)))
  (add-hook 'kill-buffer-hook
            (lambda () (beady--cancel-process beady-show--process))
            nil t)
  (beady--maybe-setup-evil))

(provide 'beady-show)
;;; beady-show.el ends here
