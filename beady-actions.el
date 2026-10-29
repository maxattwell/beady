;;; beady-actions.el --- Commands that change beads  -*- lexical-binding: t; -*-

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

;; Commands that modify beads: status changes, priority, assignee,
;; labels, comments, text fields, relations and creation, plus the
;; transient menus that group them and a small buffer for composing
;; longer text.
;;
;; Commands act on the "targets": the marked beads in a list buffer,
;; the beads in the active region, the bead at point, or the bead shown
;; in a bead buffer.  Every successful change refreshes all beady
;; buffers of the project.

;;; Code:

(require 'beady-core)
(require 'transient)

(defcustom beady-compose-major-mode nil
  "Major mode used in buffers for composing descriptions and comments.
When nil, use `gfm-mode' if markdown-mode is installed, otherwise
`text-mode'."
  :type '(choice (const :tag "Automatic" nil) function)
  :group 'beady)

(defcustom beady-compose-hook nil
  "Hook run after a compose buffer has been set up."
  :type 'hook
  :group 'beady)

;;;; Targets

(defvar beady--transient-targets nil
  "Cons of (PREFIX . IDS) captured when a targeting menu was opened.")

(defun beady--buffer-targets ()
  "Return the IDs of the beads the current buffer would act on."
  (let ((ids (and beady--targets-function (funcall beady--targets-function))))
    (when (region-active-p)
      (beady--deactivate-selection))
    ids))

(defun beady--targets ()
  "Return the IDs of the beads to act on, or signal a `user-error'."
  (or (and transient-current-prefix
           (eq (car beady--transient-targets) transient-current-command)
           (cdr beady--transient-targets))
      (beady--buffer-targets)
      (user-error "No bead at point")))

(defun beady--capture-targets (prefix)
  "Remember the current targets for the transient PREFIX."
  (setq beady--transient-targets
        (cons prefix (or (beady--buffer-targets)
                         (user-error "No bead at point")))))

(defun beady--single-target ()
  "Return the single bead ID to act on, or signal a `user-error'."
  (let ((ids (beady--targets)))
    (when (cdr ids)
      (user-error "This command acts on a single bead; unmark the others first"))
    (car ids)))

(defun beady--describe-targets (ids)
  "Return a short description of IDS for prompts and messages."
  (if (cdr ids)
      (format "%d beads" (length ids))
    (car ids)))

(defun beady--targets-heading (verb)
  "Return a transient heading for VERB applied to the captured targets."
  (let* ((ids (cdr beady--transient-targets))
         (issue (and ids (null (cdr ids)) (beady--lookup-issue (car ids)))))
    (concat (propertize verb 'face 'transient-heading) " "
            (propertize (beady--describe-targets ids) 'face 'beady-id)
            (if issue
                (concat " " (truncate-string-to-width
                             (or (alist-get 'title issue) "") 50 nil nil "…"))
              ""))))

(defun beady--mutate (args &optional message forcible)
  "Run bd with ARGS in the current project, then refresh its buffers.
Display MESSAGE on success.  When FORCIBLE is non-nil and bd refuses
the change with a hint to use --force (e.g. closing an epic with open
children, or reassigning a bead claimed by someone else), show the
reason and offer to retry with --force.  Buffers are refreshed even
when bd fails, since multi-bead updates may partially succeed."
  (let* ((root (beady--current-root))
         (default-directory root))
    (unwind-protect
        (prog1 (condition-case err
                   (beady--run args)
                 (beady-error
                  (let ((reason (cadr err)))
                    (if (and forcible (string-match-p "--force" reason)
                             (yes-or-no-p (format "%s\nRetry with --force? " reason)))
                        (beady--run (append args '("--force")))
                      (signal (car err) (cdr err))))))
          (when message (message "%s" message)))
      (beady-refresh-buffers root))))

(defun beady--issue-full (id)
  "Return the data of bead ID, fetching it when no buffer knows it."
  (or (beady--lookup-issue id)
      (let ((default-directory (beady--current-root)))
        (car (beady--run-json (list "show" id))))))

;;;; Completion helpers

(defvar beady--issue-history nil "History of bead IDs entered in prompts.")
(defvar beady--label-history nil "History of labels entered in prompts.")
(defvar beady--assignee-history nil "History of assignees entered in prompts.")

(defvar-local beady--issues-function nil
  "Function returning all issues known to the current buffer.")

(defun beady--known-issues (&optional root)
  "Return all issues of ROOT, preferably from an existing list buffer."
  (let ((root (or root (beady--current-root))))
    (or (seq-some (lambda (buf)
                    (with-current-buffer buf
                      (and beady--issues-function
                           (funcall beady--issues-function))))
                  (beady--buffers root))
        (let ((default-directory root))
          (beady--run-json '("list" "--all" "--limit" "0" "--brief"))))))

(defun beady--ordered-completion-table (candidates)
  "Return a completion table for CANDIDATES that keeps their order."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity)
                   (cycle-sort-function . identity))
      (complete-with-action action candidates string pred))))

(defun beady--read-issue (prompt &optional predicate)
  "Read a bead ID with PROMPT, offering beads matching PREDICATE.
Epics are offered first.  Return the empty string for empty input."
  (let* ((issues (seq-filter (or predicate #'always) (beady--known-issues)))
         (issues (sort (copy-sequence issues)
                       (lambda (a b)
                         (and (equal (alist-get 'issue_type a) "epic")
                              (not (equal (alist-get 'issue_type b) "epic"))))))
         (table (mapcar (lambda (issue)
                          (cons (format "%s  %s" (beady--id issue)
                                        (alist-get 'title issue))
                                (beady--id issue)))
                        issues))
         (choice (completing-read prompt
                                  (beady--ordered-completion-table
                                   (mapcar #'car table))
                                  nil nil nil 'beady--issue-history)))
    (or (cdr (assoc choice table))
        (car (split-string choice))
        "")))

(defun beady--known-values (key)
  "Return the distinct non-empty values of KEY across known issues.
KEY may name a string field or a list field such as `labels'."
  (let ((values nil))
    (dolist (issue (ignore-errors (beady--known-issues)))
      (let ((value (alist-get key issue)))
        (dolist (v (if (listp value) value (list value)))
          (when (and (stringp v) (not (string-empty-p v)))
            (push v values)))))
    (sort (delete-dups values) #'string<)))

(defun beady--read-assignee (prompt &optional initial)
  "Read an assignee with PROMPT and INITIAL input."
  (completing-read prompt (beady--known-values 'assignee) nil nil initial
                   'beady--assignee-history))

(defun beady--read-labels (prompt &optional candidates initial)
  "Read a list of labels with PROMPT.
CANDIDATES default to all known labels; INITIAL is the initial input."
  (completing-read-multiple prompt (or candidates (beady--known-values 'labels))
                            nil nil initial 'beady--label-history))

(defun beady--read-priority (prompt)
  "Read a priority (0-4) with PROMPT."
  (let* ((choices (mapcar (lambda (p) (format "P%d %s" (car p) (cdr p)))
                          beady-priority-names))
         (choice (completing-read prompt (beady--ordered-completion-table choices)
                                  nil t)))
    (string-to-number (substring choice 1 2))))

;;;; Status

(defun beady--read-close-reason (ids)
  "Read a close reason for IDS."
  (read-string (format "Close %s, reason (optional): "
                       (beady--describe-targets ids))))

(defun beady--close (ids reason)
  "Close IDS with REASON.
Offer to force the close when bd refuses, e.g. because of open children."
  (beady--mutate (append '("close") ids
                         (unless (string-empty-p reason)
                           (list (concat "--reason=" reason))))
                 (format "Closed %s" (beady--describe-targets ids))
                 t))

(defun beady--open (ids)
  "Return IDS to the open status, using the right bd command for each.
Closed beads are reopened, deferred ones undeferred and others updated."
  (let ((statuses (beady--statuses))
        closed deferred other)
    (dolist (id ids)
      (let ((status (alist-get 'status (beady--lookup-issue id))))
        (cond ((and status (beady--status-done-p status statuses)) (push id closed))
              ((equal status "deferred") (push id deferred))
              (t (push id other)))))
    (let* ((root (beady--current-root))
           (default-directory root))
      (unwind-protect
          (progn
            (when closed (beady--run (cons "reopen" (nreverse closed))))
            (when deferred (beady--run (cons "undefer" (nreverse deferred))))
            (when other
              (beady--run (append '("update") (nreverse other) '("--status=open"))))
            (message "Opened %s" (beady--describe-targets ids)))
        (beady-refresh-buffers root)))))

(defun beady-set-status (status &optional ids)
  "Set the status of the targeted beads (IDS) to STATUS.
Closing asks for a reason and deferring for a date.  Opening a closed
bead reopens it."
  (interactive
   (list (completing-read "Set status: "
                          (beady--ordered-completion-table
                           (beady--ordered-statuses (beady--statuses)))
                          nil t)))
  (let ((ids (or ids (beady--targets))))
    (pcase status
      ("closed" (beady--close ids (beady--read-close-reason ids)))
      ("open" (beady--open ids))
      ("deferred" (beady-defer ids (beady--read-defer-until ids)))
      (_ (beady--mutate (append '("update") ids (list (concat "--status=" status)))
                        (format "%s → %s" (beady--describe-targets ids) status)
                        t)))))

(defun beady-status-open (ids)
  "Set the targeted beads (IDS) to open, reopening closed ones."
  (interactive (list (beady--targets)))
  (beady--open ids))

(defun beady-status-in-progress (ids)
  "Set the targeted beads (IDS) to in_progress."
  (interactive (list (beady--targets)))
  (beady-set-status "in_progress" ids))

(defun beady-status-blocked (ids)
  "Set the targeted beads (IDS) to blocked."
  (interactive (list (beady--targets)))
  (beady-set-status "blocked" ids))

(defun beady-close (ids reason)
  "Close the targeted beads (IDS) with an optional REASON."
  (interactive (let ((ids (beady--targets)))
                 (list ids (beady--read-close-reason ids))))
  (beady--close ids reason))

(defun beady-reopen (ids)
  "Reopen the targeted beads (IDS)."
  (interactive (list (beady--targets)))
  (beady--mutate (cons "reopen" ids)
                 (format "Reopened %s" (beady--describe-targets ids))))

(defun beady--read-defer-until (ids)
  "Read the date until which IDS are deferred."
  (read-string (format "Defer %s until (e.g. tomorrow, +2w, 2026-12-01; empty = indefinitely): "
                       (beady--describe-targets ids))))

(defun beady-defer (ids until)
  "Defer the targeted beads (IDS) UNTIL a date, or indefinitely if empty."
  (interactive (let ((ids (beady--targets)))
                 (list ids (beady--read-defer-until ids))))
  (beady--mutate (append '("defer") ids
                         (unless (string-empty-p until)
                           (list (concat "--until=" until))))
                 (format "Deferred %s" (beady--describe-targets ids))))

(defun beady-claim (ids)
  "Claim the targeted beads (IDS): assign them to you and start them."
  (interactive (list (beady--targets)))
  (beady--mutate (append '("update") ids '("--claim"))
                 (format "Claimed %s" (beady--describe-targets ids))))

(defun beady-unclaim (ids)
  "Release your claim on the targeted beads (IDS)."
  (interactive (list (beady--targets)))
  (beady--mutate (cons "unclaim" ids)
                 (format "Unclaimed %s" (beady--describe-targets ids))
                 t))

(transient-define-prefix beady-status-menu ()
  "Change the status of the bead at point or of the marked beads."
  [:description (lambda () (beady--targets-heading "Status of"))
   ["Set status"
    ("o" "Open" beady-status-open)
    ("i" "In progress" beady-status-in-progress)
    ("b" "Blocked" beady-status-blocked)]
   [""
    ("d" "Deferred…" beady-defer)
    ("c" "Closed…" beady-close)
    ("s" "Other status…" beady-set-status)]
   ["Claim"
    ("C" "Claim (assign to me + in progress)" beady-claim)
    ("U" "Unclaim" beady-unclaim)]]
  (interactive)
  (beady--capture-targets 'beady-status-menu)
  (transient-setup 'beady-status-menu))

;;;; Priority

(defun beady-set-priority (priority ids)
  "Set the priority of the targeted beads (IDS) to PRIORITY (0-4)."
  (interactive (let ((ids (beady--targets)))
                 (list (beady--read-priority
                        (format "Priority for %s: " (beady--describe-targets ids)))
                       ids)))
  (beady--mutate (append '("update") ids (list (format "--priority=%d" priority)))
                 (format "%s → P%d" (beady--describe-targets ids) priority)))

(defmacro beady--define-priority-command (priority)
  "Define a command setting the priority of the targets to PRIORITY."
  `(defun ,(intern (format "beady-set-priority-%d" priority)) (ids)
     ,(format "Set the priority of the targeted beads (IDS) to P%d (%s)."
              priority (beady--priority-name priority))
     (interactive (list (beady--targets)))
     (beady-set-priority ,priority ids)))

(beady--define-priority-command 0)
(beady--define-priority-command 1)
(beady--define-priority-command 2)
(beady--define-priority-command 3)
(beady--define-priority-command 4)

(transient-define-prefix beady-priority-menu ()
  "Change the priority of the bead at point or of the marked beads."
  [:description (lambda () (beady--targets-heading "Priority of"))
   [("0" "P0 Critical" beady-set-priority-0)
    ("1" "P1 High" beady-set-priority-1)
    ("2" "P2 Medium" beady-set-priority-2)]
   [("3" "P3 Low" beady-set-priority-3)
    ("4" "P4 Backlog" beady-set-priority-4)]]
  (interactive)
  (beady--capture-targets 'beady-priority-menu)
  (transient-setup 'beady-priority-menu))

;;;; Assignee and labels

(defun beady-assign (assignee ids)
  "Assign the targeted beads (IDS) to ASSIGNEE; empty means unassign."
  (interactive (let ((ids (beady--targets)))
                 (list (beady--read-assignee
                        (format "Assign %s to (empty to unassign): "
                                (beady--describe-targets ids)))
                       ids)))
  (beady--mutate (append '("update") ids (list (concat "--assignee=" assignee)))
                 (if (string-empty-p assignee)
                     (format "Unassigned %s" (beady--describe-targets ids))
                   (format "Assigned %s to %s" (beady--describe-targets ids) assignee))
                 t))

(defun beady--target-labels (ids)
  "Return the union of the labels of IDS."
  (delete-dups (seq-mapcat (lambda (id) (alist-get 'labels (beady--lookup-issue id)))
                           ids)))

(defun beady-add-labels (labels ids)
  "Add LABELS to the targeted beads (IDS)."
  (interactive (let ((ids (beady--targets)))
                 (list (beady--read-labels
                        (format "Add labels to %s: " (beady--describe-targets ids)))
                       ids)))
  (unless labels (user-error "No labels given"))
  (beady--mutate (append '("update") ids
                         (mapcar (lambda (l) (concat "--add-label=" l)) labels))
                 (format "Labeled %s: %s" (beady--describe-targets ids)
                         (string-join labels ", "))))

(defun beady-remove-labels (labels ids)
  "Remove LABELS from the targeted beads (IDS)."
  (interactive (let* ((ids (beady--targets))
                      (current (beady--target-labels ids)))
                 (unless current (user-error "No labels to remove"))
                 (list (beady--read-labels
                        (format "Remove labels from %s: " (beady--describe-targets ids))
                        current)
                       ids)))
  (unless labels (user-error "No labels given"))
  (beady--mutate (append '("update") ids
                         (mapcar (lambda (l) (concat "--remove-label=" l)) labels))
                 (format "Removed %s from %s" (string-join labels ", ")
                         (beady--describe-targets ids))))

(defun beady-set-labels (labels ids)
  "Replace the labels of the targeted beads (IDS) with LABELS."
  (interactive (let* ((ids (beady--targets))
                      (current (beady--target-labels ids)))
                 (list (beady--read-labels
                        (format "Labels of %s: " (beady--describe-targets ids))
                        nil (and current (concat (string-join current ",") ",")))
                       ids)))
  (beady--mutate (append '("update") ids
                         (if labels
                             (mapcar (lambda (l) (concat "--set-labels=" l)) labels)
                           (mapcar (lambda (l) (concat "--remove-label=" l))
                                   (or (beady--target-labels ids)
                                       (user-error "No labels to remove")))))
                 (format "Labels of %s: %s" (beady--describe-targets ids)
                         (if labels (string-join labels ", ") "none"))))

(transient-define-prefix beady-labels-menu ()
  "Change the labels of the bead at point or of the marked beads."
  [:description (lambda () (beady--targets-heading "Labels of"))
   [("a" "Add…" beady-add-labels)
    ("r" "Remove…" beady-remove-labels)
    ("s" "Set…" beady-set-labels)]]
  (interactive)
  (beady--capture-targets 'beady-labels-menu)
  (transient-setup 'beady-labels-menu))

;;;; Compose buffers

(defvar-local beady-compose--callback nil
  "Function called with the text of the compose buffer.")

(defvar-local beady-compose--window-config nil
  "Window configuration to restore when the compose buffer is done.")

(defvar-local beady-compose--heading nil
  "Description of the edit shown in the header line.")

(defvar-keymap beady-compose-mode-map
  :doc "Keymap for `beady-compose-mode'."
  "C-c C-c" #'beady-compose-finish
  "C-c C-k" #'beady-compose-cancel)

(define-minor-mode beady-compose-mode
  "Minor mode for composing text that is sent to Beads.
\\<beady-compose-mode-map>Type \\[beady-compose-finish] to send it or \\[beady-compose-cancel] to cancel."
  :lighter " Beady-Compose"
  :keymap beady-compose-mode-map)

(defun beady--compose-major-mode ()
  "Return the major mode to use in compose buffers."
  (or beady-compose-major-mode
      (if (or (fboundp 'gfm-mode) (require 'markdown-mode nil t))
          'gfm-mode
        'text-mode)))

(defun beady-compose--header-line ()
  "Return the header line of a compose buffer."
  (concat beady-compose--heading "  "
          (beady--hints '((beady-compose-finish . "save")
                          (beady-compose-cancel . "cancel")))))

(defun beady-compose (name heading initial callback)
  "Pop up a buffer called NAME to edit INITIAL text.
HEADING describes the edit in the header line.  CALLBACK is called with
the trimmed text when the user finishes with \\<beady-compose-mode-map>\\[beady-compose-finish]."
  (let ((root (beady--current-root))
        (config (current-window-configuration))
        (buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (funcall (beady--compose-major-mode))
      (setq default-directory root)
      (setq beady--root root)
      (insert (or initial ""))
      (goto-char (point-min))
      (set-buffer-modified-p nil)
      (beady-compose-mode 1)
      (setq beady-compose--callback callback
            beady-compose--window-config config)
      (setq beady-compose--heading heading)
      (setq header-line-format '(:eval (beady-compose--header-line))))
    (pop-to-buffer buffer '((display-buffer-reuse-window display-buffer-below-selected)
                            (window-height . 0.4)))
    (with-current-buffer buffer
      (run-hooks 'beady-compose-hook))
    buffer))

(defun beady-compose--quit ()
  "Kill the compose buffer and restore the previous window layout."
  (let ((config beady-compose--window-config)
        (buffer (current-buffer)))
    (set-buffer-modified-p nil)
    (kill-buffer buffer)
    (when (window-configuration-p config)
      (set-window-configuration config))))

(defun beady-compose-finish ()
  "Send the text of the compose buffer to Beads.
If bd fails, the buffer is kept so that no text is lost."
  (interactive)
  (unless beady-compose-mode (user-error "Not in a beady compose buffer"))
  (let ((text (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
    (funcall beady-compose--callback text)
    (beady-compose--quit)))

(defun beady-compose-cancel ()
  "Discard the compose buffer."
  (interactive)
  (unless beady-compose-mode (user-error "Not in a beady compose buffer"))
  (when (or (not (buffer-modified-p))
            (yes-or-no-p "Discard this text? "))
    (beady-compose--quit)))

;;;; Comments and text fields

(defun beady-add-comment (ids)
  "Write a comment for the targeted beads (IDS) in a compose buffer."
  (interactive (list (beady--targets)))
  (beady-compose (format "*beady comment: %s*" (beady--describe-targets ids))
                 (format "Comment on %s." (beady--describe-targets ids))
                 ""
                 (lambda (text)
                   (when (string-empty-p text) (user-error "Empty comment"))
                   (let ((root (beady--current-root)))
                     (unwind-protect
                         (let ((default-directory root))
                           (dolist (id ids)
                             (beady--run (list "comment" id "--" text))))
                       (beady-refresh-buffers root)))
                   (message "Commented on %s" (beady--describe-targets ids)))))

(defun beady-append-note (ids)
  "Append a note to the notes of the targeted beads (IDS)."
  (interactive (list (beady--targets)))
  (beady-compose (format "*beady note: %s*" (beady--describe-targets ids))
                 (format "Note to append to %s." (beady--describe-targets ids))
                 ""
                 (lambda (text)
                   (when (string-empty-p text) (user-error "Empty note"))
                   (let ((root (beady--current-root)))
                     (unwind-protect
                         (let ((default-directory root))
                           (dolist (id ids)
                             (beady--run (list "note" id "--" text))))
                       (beady-refresh-buffers root)))
                   (message "Added note to %s" (beady--describe-targets ids)))))

(defconst beady--text-fields
  '((description "description" "--description=")
    (design "design" "--design=")
    (acceptance_criteria "acceptance criteria" "--acceptance=")
    (notes "notes" "--notes="))
  "Long text fields: (KEY NAME FLAG).")

(defun beady-edit-field (id field)
  "Edit the long text FIELD of bead ID in a compose buffer.
FIELD is one of the keys of `beady--text-fields'."
  (interactive
   (list (beady--single-target)
         (intern (completing-read "Edit field: "
                                  (mapcar (lambda (f) (symbol-name (car f)))
                                          beady--text-fields)
                                  nil t))))
  (pcase-let* ((`(,_ ,name ,flag) (assq field beady--text-fields))
               (issue (beady--issue-full id)))
    (beady-compose (format "*beady %s: %s*" name id)
                   (format "Edit the %s of %s." name id)
                   (alist-get field issue)
                   (lambda (text)
                     (beady--mutate (list "update" id (concat flag text))
                                    (format "Updated the %s of %s" name id))))))

(defun beady-edit-description (id)
  "Edit the description of bead ID."
  (interactive (list (beady--single-target)))
  (beady-edit-field id 'description))

(defun beady-edit-design (id)
  "Edit the design notes of bead ID."
  (interactive (list (beady--single-target)))
  (beady-edit-field id 'design))

(defun beady-edit-acceptance (id)
  "Edit the acceptance criteria of bead ID."
  (interactive (list (beady--single-target)))
  (beady-edit-field id 'acceptance_criteria))

(defun beady-edit-notes (id)
  "Edit the notes of bead ID."
  (interactive (list (beady--single-target)))
  (beady-edit-field id 'notes))

(defun beady-edit-title (id title)
  "Change the title of bead ID to TITLE."
  (interactive (let ((id (beady--single-target)))
                 (list id (read-string "Title: "
                                       (alist-get 'title (beady--lookup-issue id))))))
  (when (string-blank-p title) (user-error "The title cannot be empty"))
  (beady--mutate (list "update" id (concat "--title=" title))
                 (format "Renamed %s" id)))

(defun beady-edit-type (type ids)
  "Change the issue type of the targeted beads (IDS) to TYPE."
  (interactive (let ((ids (beady--targets)))
                 (list (completing-read (format "Type of %s: " (beady--describe-targets ids))
                                        (beady--types) nil t)
                       ids)))
  (beady--mutate (append '("update") ids (list (concat "--type=" type)))
                 (format "%s is now a %s" (beady--describe-targets ids) type)))

(defun beady-edit-due (due ids)
  "Set the due date of the targeted beads (IDS) to DUE; empty clears it."
  (interactive (let ((ids (beady--targets)))
                 (list (read-string (format "Due date for %s (e.g. friday, +3d, 2026-12-01; empty clears): "
                                            (beady--describe-targets ids)))
                       ids)))
  (beady--mutate (append '("update") ids (list (concat "--due=" due)))
                 (format "Due date of %s updated" (beady--describe-targets ids))))

(defun beady-edit-estimate (minutes ids)
  "Set the time estimate of the targeted beads (IDS) to MINUTES."
  (interactive (let ((ids (beady--targets)))
                 (list (read-number (format "Estimate for %s in minutes: "
                                            (beady--describe-targets ids)))
                       ids)))
  (beady--mutate (append '("update") ids (list (format "--estimate=%d" minutes)))
                 (format "Estimate of %s updated" (beady--describe-targets ids))))

(defun beady-edit-external-ref (ref ids)
  "Set the external reference of the targeted beads (IDS) to REF."
  (interactive (let ((ids (beady--targets)))
                 (list (read-string (format "External ref for %s (e.g. gh-9): "
                                            (beady--describe-targets ids)))
                       ids)))
  (beady--mutate (append '("update") ids (list (concat "--external-ref=" ref)))
                 (format "External ref of %s updated" (beady--describe-targets ids))))

;;;; Relations

(defun beady-set-parent (parent ids)
  "Move the targeted beads (IDS) under PARENT; empty removes the parent."
  (interactive (let ((ids (beady--targets)))
                 (list (beady--read-issue
                        (format "Parent of %s (empty to remove): " (beady--describe-targets ids))
                        (lambda (issue) (not (member (beady--id issue) ids))))
                       ids)))
  (beady--mutate (append '("update") ids (list (concat "--parent=" parent)))
                 (if (string-empty-p parent)
                     (format "Removed the parent of %s" (beady--describe-targets ids))
                   (format "Moved %s under %s" (beady--describe-targets ids) parent))))

(defun beady-add-blocker (blocker ids)
  "Make the targeted beads (IDS) depend on (be blocked by) BLOCKER."
  (interactive (let ((ids (beady--targets)))
                 (list (beady--read-issue
                        (format "%s is blocked by: " (beady--describe-targets ids))
                        (lambda (issue) (not (member (beady--id issue) ids))))
                       ids)))
  (when (string-empty-p blocker) (user-error "No bead given"))
  (let ((root (beady--current-root)))
    (unwind-protect
        (let ((default-directory root))
          (dolist (id ids)
            (beady--run (list "dep" "add" id blocker)))
          (message "%s now blocked by %s" (beady--describe-targets ids) blocker))
      (beady-refresh-buffers root))))

(defun beady--blockers (issue)
  "Return the IDs that ISSUE depends on with a blocking dependency."
  (cl-loop for dep in (alist-get 'dependencies issue)
           for type = (or (alist-get 'type dep) (alist-get 'dependency_type dep))
           unless (member type '("parent-child" "related" "relates-to"
                                 "discovered-from" "replies-to" "duplicates"
                                 "supersedes"))
           collect (or (alist-get 'depends_on_id dep) (alist-get 'id dep))))

(defun beady-remove-blocker (blocker id)
  "Remove the dependency of bead ID on BLOCKER."
  (interactive (let* ((id (beady--single-target))
                      (blockers (beady--blockers (beady--issue-full id))))
                 (unless blockers (user-error "%s has no blocking dependencies" id))
                 (list (completing-read (format "Stop %s depending on: " id) blockers nil t)
                       id)))
  (beady--mutate (list "dep" "remove" id blocker)
                 (format "%s no longer depends on %s" id blocker)))

;;;; Edit menu

(transient-define-prefix beady-edit-menu ()
  "Edit fields and relations of the bead at point or of the marked beads."
  [:description (lambda () (beady--targets-heading "Edit"))
   ["Text"
    ("t" "Title…" beady-edit-title)
    ("d" "Description" beady-edit-description)
    ("D" "Design" beady-edit-design)
    ("a" "Acceptance criteria" beady-edit-acceptance)
    ("n" "Notes" beady-edit-notes)
    ("N" "Append note" beady-append-note)]
   ["Fields"
    ("T" "Type…" beady-edit-type)
    ("p" "Priority…" beady-set-priority)
    ("A" "Assignee…" beady-assign)
    ("u" "Due date…" beady-edit-due)
    ("E" "Estimate…" beady-edit-estimate)
    ("x" "External ref…" beady-edit-external-ref)]
   ["Relations"
    ("P" "Parent…" beady-set-parent)
    ("b" "Add blocker…" beady-add-blocker)
    ("B" "Remove blocker…" beady-remove-blocker)]]
  (interactive)
  (beady--capture-targets 'beady-edit-menu)
  (transient-setup 'beady-edit-menu))

;;;; Creating beads

(defun beady--transient-read-type (prompt initial history)
  "Read an issue type for transient with PROMPT, INITIAL and HISTORY."
  (completing-read prompt (beady--types) nil nil initial history))

(defun beady--transient-read-assignee (prompt initial _history)
  "Read an assignee for transient with PROMPT and INITIAL."
  (beady--read-assignee prompt initial))

(defun beady--transient-read-labels (prompt initial _history)
  "Read labels for transient with PROMPT and INITIAL."
  (string-join (beady--read-labels prompt nil initial) ","))

(defun beady--transient-read-parent (prompt _initial _history)
  "Read a parent bead for transient with PROMPT."
  (beady--read-issue prompt))

(defvar-local beady--focus-function nil
  "Function called with a bead ID to move point to it after a refresh.")

(defun beady--created (id root)
  "Refresh the buffers of ROOT and move to the newly created bead ID."
  (dolist (buf (beady--buffers root))
    (with-current-buffer buf
      (when beady--focus-function
        (funcall beady--focus-function id))))
  (beady-refresh-buffers root))

(defun beady-create (title &optional args)
  "Create a bead titled TITLE, passing ARGS from `beady-create-menu'."
  (interactive (list (read-string "Title of the new bead: ")
                     (transient-args 'beady-create-menu)))
  (when (string-blank-p title) (user-error "A title is required"))
  (let* ((root (beady--current-root))
         (default-directory root)
         (issue (beady--run-json (append (list "create" (concat "--title=" title))
                                         args)))
         (id (alist-get 'id issue)))
    (beady--created id root)
    (message "Created %s: %s" id title)
    id))

(defun beady-create-with-description (&optional args)
  "Create a bead in a compose buffer, passing ARGS from `beady-create-menu'.
The first line is the title, the rest the description."
  (interactive (list (transient-args 'beady-create-menu)))
  (beady-compose "*beady new bead*"
                 "New bead: first line is the title, the rest the description."
                 ""
                 (lambda (text)
                   (let* ((lines (split-string text "\n"))
                          (title (string-trim (car lines)))
                          (description (string-trim (string-join (cdr lines) "\n"))))
                     (beady-create title
                                   (append args
                                           (unless (string-empty-p description)
                                             (list (concat "--description=" description)))))))))

(transient-define-prefix beady-create-menu ()
  "Create a new bead."
  ["Options"
   ("-t" "Type" "--type=" :reader beady--transient-read-type)
   ("-p" "Priority" "--priority=" :choices ("0" "1" "2" "3" "4"))
   ("-a" "Assignee" "--assignee=" :reader beady--transient-read-assignee)
   ("-l" "Labels" "--labels=" :reader beady--transient-read-labels)
   ("-P" "Parent" "--parent=" :reader beady--transient-read-parent)
   ("-d" "Due date" "--due=")]
  ["Create"
   ("c" "Create with a title" beady-create)
   ("C" "Create with title and description…" beady-create-with-description)])

;;;; Synchronization and version control

(defun beady--remotes (&optional root)
  "Return the parsed `bd dolt remote list' entries of ROOT, or nil."
  (let ((default-directory (or root (beady--current-root))))
    (condition-case nil
        (let ((json (beady--run-json '("dolt" "remote" "list"))))
          (and (beady--json-array-p json) json))
      (beady-error nil))))

(defun beady--transient-read-remote (prompt initial _history)
  "Read a Dolt remote name for transient with PROMPT and INITIAL."
  (completing-read prompt (mapcar (lambda (r) (alist-get 'name r)) (beady--remotes))
                   nil nil initial))

(defun beady--sync-args ()
  "Return the active transient arguments of `beady-sync-menu'."
  (and (eq transient-current-command 'beady-sync-menu)
       (transient-args 'beady-sync-menu)))

(defun beady--sync-option (args prefix)
  "Return the option in ARGS starting with PREFIX, or nil."
  (seq-find (lambda (arg) (string-prefix-p prefix arg)) args))

(defun beady--format-sync-result (json)
  "Return a one-line summary of the `bd sync --json' payload JSON."
  (let ((status (and (listp json) (consp (car-safe json)) (alist-get 'status json)))
        (pulled (and (listp json) (alist-get 'pulled json)))
        (pushed (and (listp json) (alist-get 'pushed json)))
        (corrected (and (listp json) (alist-get 'rows_corrected json))))
    (pcase status
      ("no-remote" "Beads sync: no remote configured")
      ("ok"
       (let ((parts nil))
         (when pulled (push "pulled" parts))
         (when pushed (push "pushed" parts))
         (when (and (numberp corrected) (> corrected 0))
           (push (format "%d blocked flag%s repaired"
                         corrected (if (= corrected 1) "" "s"))
                 parts))
         (if parts
             (format "Beads synced (%s)" (string-join (nreverse parts) ", "))
           "Beads synced (up to date)")))
      (_ "Beads synced"))))

(defun beady--format-sync-failure (msg exit stdout)
  "Return a human-readable message for a failed `bd sync'.
MSG is the default error message, EXIT the exit status and STDOUT the
output of `bd sync --json'."
  (let* ((json (ignore-errors (beady--parse-json stdout)))
         (tables (and (listp json) (consp (car-safe json))
                      (alist-get 'conflicts json))))
    (pcase exit
      (2 (format "Beads sync halted on merge conflict%s; inspect with M-x beady-conflicts"
                 (if (and (listp tables) tables)
                     (format " in %s" (string-join tables ", "))
                   "")))
      (3 "Beads sync: retries exhausted (push race or busy working set); try again")
      (4 "Beads sync halted: dirty working set is stuck; commit or clear pending changes")
      (_ (format "Beads sync failed: %s" msg)))))

;;;###autoload
(defun beady-sync (&optional args)
  "Synchronize the current Beads project with its Dolt remote.
Runs `bd sync' asynchronously (pull, conflict check, recompute
blocked flags and push) and refreshes open beady buffers when done.
ARGS are additional flags from `beady-sync-menu'."
  (interactive (list (beady--sync-args)))
  (let* ((root (beady--current-root))
         (default-directory root)
         (flags (seq-filter (lambda (a)
                              (or (string-prefix-p "--remote=" a)
                                  (member a '("--no-adopt" "--yes"))))
                            args)))
    (message "Syncing %s…" (beady--project-name root))
    (beady--run-async
     (append '("--json" "sync") flags)
     (lambda (stdout)
       (beady-refresh-buffers root)
       (message "%s" (beady--format-sync-result (beady--parse-json stdout))))
     (lambda (msg exit stdout _stderr)
       (beady-refresh-buffers root)
       (message "%s" (beady--format-sync-failure msg exit stdout))))))

(defun beady-dolt-pull (&optional args)
  "Pull commits from the Dolt remote into the current Beads project.
ARGS are additional flags from `beady-sync-menu'."
  (interactive (list (beady--sync-args)))
  (let* ((root (beady--current-root))
         (default-directory root)
         (flags (seq-filter (lambda (a)
                              (or (string-prefix-p "--remote=" a)
                                  (string-prefix-p "--strategy=" a)))
                            args)))
    (message "Pulling %s…" (beady--project-name root))
    (beady--run-async
     (append '("dolt" "pull") flags)
     (lambda (_stdout)
       (beady-refresh-buffers root)
       (message "Pulled %s" (beady--project-name root)))
     (lambda (msg &rest _)
       (beady-refresh-buffers root)
       (message "Pull failed: %s" msg)))))

(defun beady-dolt-push (&optional args)
  "Push local Dolt commits of the current Beads project to its remote.
ARGS are additional flags from `beady-sync-menu'."
  (interactive (list (beady--sync-args)))
  (let* ((root (beady--current-root))
         (default-directory root)
         (flags (seq-filter (lambda (a)
                              (or (string-prefix-p "--remote=" a)
                                  (member a '("--force" "--no-adopt" "--yes"))))
                            args)))
    (when (and (member "--force" flags)
               (not (yes-or-no-p (format "Force push %s (overwriting remote changes)? "
                                         (beady--project-name root)))))
      (user-error "Aborted"))
    (message "Pushing %s…" (beady--project-name root))
    (beady--run-async
     (append '("dolt" "push") flags)
     (lambda (_stdout)
       (beady-refresh-buffers root)
       (message "Pushed %s" (beady--project-name root)))
     (lambda (msg &rest _)
       (message "Push failed: %s" msg)))))

(defun beady-vc-commit (message)
  "Create a Dolt commit with MESSAGE for pending changes in the project."
  (interactive (list (read-string "Commit message: ")))
  (when (string-blank-p message) (user-error "A commit message is required"))
  (let* ((root (beady--current-root))
         (default-directory root)
         (json (beady--run-json (list "vc" "commit" (concat "--message=" message)))))
    (beady-refresh-buffers root)
    (if (alist-get 'committed json)
        (let ((hash (or (alist-get 'hash json) "")))
          (message "Committed %s: %s"
                   (substring hash 0 (min 8 (length hash))) message))
      (message "%s" (or (alist-get 'message json) "Nothing to commit")))))

(defun beady-dolt-remote-add (name url)
  "Add a Dolt remote called NAME pointing to URL."
  (interactive
   (list (read-string "Remote name (e.g. origin): "
                      (unless (beady--remotes) "origin"))
         (read-string "Remote URL: ")))
  (when (string-blank-p name) (user-error "A remote name is required"))
  (when (string-blank-p url) (user-error "A remote URL is required"))
  (let* ((root (beady--current-root))
         (default-directory root))
    (beady--run (list "dolt" "remote" "add" name url))
    (message "Added remote %s → %s" name url)))

(defun beady-dolt-remote-remove (name)
  "Remove the Dolt remote called NAME."
  (interactive
   (let ((remotes (mapcar (lambda (r) (alist-get 'name r)) (beady--remotes))))
     (unless remotes (user-error "No Dolt remotes configured"))
     (list (completing-read "Remove remote: " remotes nil t))))
  (when (string-blank-p name) (user-error "No remote given"))
  (let* ((root (beady--current-root))
         (default-directory root))
    (beady--run (list "dolt" "remote" "remove" name))
    (message "Removed remote %s" name)))

(defun beady-vc-status ()
  "Display the version control, Dolt engine, remote and conflict status."
  (interactive)
  (let* ((root (beady--current-root))
         (default-directory root)
         (name (beady--project-name root))
         (vc (ignore-errors (beady--run-json '("vc" "status"))))
         (dolt (ignore-errors (beady--run-json '("dolt" "status"))))
         (remotes (beady--remotes root))
         (conflicts (ignore-errors (beady--run-json '("conflicts" "list"))))
         (buffer (get-buffer-create (format "*beady vc: %s*" name))))
    (with-current-buffer buffer
      (special-mode)
      (setq default-directory root
            beady--root root
            revert-buffer-function (lambda (&rest _) (beady-vc-status)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Beads version control — %s\n\n" name) 'face 'bold))
        (when (and (listp vc) (consp (car-safe vc)))
          (insert (propertize "Branch    " 'face 'beady-field-name)
                  (or (alist-get 'branch vc) "?") "\n"
                  (propertize "Commit    " 'face 'beady-field-name)
                  (propertize (or (alist-get 'commit vc) "?") 'face 'beady-id) "\n"))
        (when (and (listp dolt) (consp (car-safe dolt)))
          (insert (propertize "Engine    " 'face 'beady-field-name)
                  (or (alist-get 'mode dolt) "?")
                  (if (alist-get 'server_running dolt) " (server running)" "")
                  "\n")
          (when-let* ((dir (alist-get 'data_dir dolt)))
            (insert (propertize "Data dir  " 'face 'beady-field-name)
                    (abbreviate-file-name dir) "\n")))
        (insert "\n" (propertize "Remotes\n" 'face 'beady-section-heading))
        (if (null remotes)
            (insert (propertize "  None configured\n" 'face 'beady-dim))
          (dolist (remote remotes)
            (let-alist remote
              (insert "  " (propertize (or .name "?") 'face 'bold)
                      "  " (or .url "")
                      (if (and .status (not (equal .status "ok")))
                          (concat "  " (propertize (format "[%s]" .status) 'face 'warning))
                        "")
                      "\n"))))
        (insert "\n" (propertize "Conflicts\n" 'face 'beady-section-heading))
        (let* ((count (or (and (listp conflicts) (alist-get 'conflicts conflicts)) 0))
               (tables (and (listp conflicts) (alist-get 'tables conflicts)))
               (merging (and (listp conflicts)
                             (alist-get 'merging (alist-get 'blockers conflicts)))))
          (if (and (eql count 0) (not merging))
              (insert (propertize "  No merge conflicts\n" 'face 'beady-dim))
            (insert (propertize (format "  %d conflict%s%s\n"
                                        count (if (= count 1) "" "s")
                                        (if merging " (merge in progress)" ""))
                                'face 'warning))
            (dolist (tbl tables)
              (let-alist tbl
                (insert (format "    %-14s %d\n" (or .table "?") (or .count 0)))))))
        (goto-char (point-min))))
    (display-buffer buffer beady-display-buffer-action)))

(defun beady--format-conflict-value (exists value)
  "Format a conflict side cell given EXISTS and VALUE."
  (cond ((not exists) (propertize "(deleted)" 'face 'beady-dim))
        ((null value) (propertize "null" 'face 'beady-dim))
        ((stringp value) value)
        (t (format "%S" value))))

(defun beady-conflicts ()
  "Display live merge conflicts of the current project."
  (interactive)
  (let* ((root (beady--current-root))
         (default-directory root)
         (name (beady--project-name root))
         (list-json (beady--run-json '("conflicts" "list")))
         (show-json (beady--run-json '("conflicts" "show")))
         (count (or (alist-get 'conflicts show-json)
                    (alist-get 'conflicts list-json) 0))
         (rows (alist-get 'rows show-json))
         (merging (alist-get 'merging (alist-get 'blockers list-json)))
         (buffer (get-buffer-create (format "*beady conflicts: %s*" name))))
    (with-current-buffer buffer
      (special-mode)
      (setq default-directory root
            beady--root root
            revert-buffer-function (lambda (&rest _) (beady-conflicts)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Beads merge conflicts — %s\n\n" name) 'face 'bold))
        (if (and (eql count 0) (null rows) (not merging))
            (insert (propertize "No merge conflicts.\n" 'face 'beady-dim))
          (when (and (eql count 0) merging)
            (insert (propertize "All conflicts resolved; merge is open (conclude it in the sync menu).\n\n"
                                'face 'warning)))
          (dolist (row rows)
            (let-alist row
              (insert (propertize (or .table "issues") 'face 'beady-section-heading)
                      " "
                      (propertize (or .issue_id .key "?") 'face 'beady-id)
                      (if (or .our_diff_type .their_diff_type)
                          (propertize (format "  (ours: %s, theirs: %s)"
                                              (or .our_diff_type "?")
                                              (or .their_diff_type "?"))
                                      'face 'beady-dim)
                        "")
                      "\n")
              (dolist (field .fields)
                (let-alist field
                  (insert "  " (propertize (string-pad (or .field .column .name "?") 16)
                                           'face 'beady-field-name)
                          "\n"
                          "    base:   " (beady--format-conflict-value
                                          (if (assq 'base_exists field) .base_exists t) .base)
                          "\n"
                          "    ours:   " (beady--format-conflict-value
                                          (if (assq 'our_exists field) .our_exists t) .ours)
                          "\n"
                          "    theirs: " (beady--format-conflict-value
                                          (if (assq 'their_exists field) .their_exists t) .theirs)
                          "\n")))
              (insert "\n"))))
        (goto-char (point-min))))
    (display-buffer buffer beady-display-buffer-action)))

(defun beady--resolve-conflicts (strategy)
  "Resolve all live merge conflicts using STRATEGY (\"ours\" or \"theirs\")."
  (unless (yes-or-no-p (format "Resolve all merge conflicts keeping %s side? " strategy))
    (user-error "Aborted"))
  (let* ((root (beady--current-root))
         (default-directory root))
    (beady--run (list "conflicts" "resolve" "--all" (concat "--" strategy)))
    (beady-refresh-buffers root)
    (when-let* ((buf (get-buffer (format "*beady conflicts: %s*" (beady--project-name root)))))
      (with-current-buffer buf (revert-buffer)))
    (message "Resolved conflicts keeping %s" strategy)))

(defun beady-conflicts-resolve-ours ()
  "Resolve all live merge conflicts keeping our side."
  (interactive)
  (beady--resolve-conflicts "ours"))

(defun beady-conflicts-resolve-theirs ()
  "Resolve all live merge conflicts taking their side."
  (interactive)
  (beady--resolve-conflicts "theirs"))

(defun beady-conflicts-conclude ()
  "Commit an open merge whose conflicts have been resolved."
  (interactive)
  (let* ((root (beady--current-root))
         (default-directory root))
    (beady--run '("conflicts" "resolve" "--conclude"))
    (beady-refresh-buffers root)
    (message "Concluded merge")))

(defun beady--sync-heading ()
  "Return the transient heading for `beady-sync-menu'."
  (let* ((root (beady--current-root))
         (default-directory root)
         (vc (ignore-errors (beady--run-json '("vc" "status"))))
         (remotes (beady--remotes root))
         (conflicts (ignore-errors (beady--run-json '("conflicts" "list"))))
         (branch (and (listp vc) (alist-get 'branch vc)))
         (commit (and (listp vc) (alist-get 'commit vc)))
         (nconf (or (and (listp conflicts) (alist-get 'conflicts conflicts)) 0))
         (merging (and (listp conflicts)
                       (alist-get 'merging (alist-get 'blockers conflicts)))))
    (concat (propertize "Sync " 'face 'transient-heading)
            (propertize (beady--project-name root) 'face 'bold)
            (if branch
                (concat "  " (propertize branch 'face 'transient-value)
                        (if (and (stringp commit) (>= (length commit) 8))
                            (propertize (concat "@" (substring commit 0 8)) 'face 'beady-dim)
                          ""))
              "")
            "  "
            (if remotes
                (mapconcat (lambda (r)
                             (concat (propertize (or (alist-get 'name r) "?") 'face 'beady-id)
                                     ":" (truncate-string-to-width
                                          (or (alist-get 'url r) "") 40 nil nil "…")))
                           remotes ", ")
              (propertize "no remote" 'face 'transient-inactive-value))
            (cond ((> nconf 0)
                   (concat "  " (propertize (format "%d conflict%s" nconf (if (= nconf 1) "" "s"))
                                            'face 'error)))
                  (merging
                   (concat "  " (propertize "merge in progress" 'face 'warning)))
                  (t "")))))

;;;###autoload
(transient-define-prefix beady-sync-menu ()
  "Synchronize and manage the Dolt database of the current Beads project."
  [:description beady--sync-heading
   ["Options"
    ("-r" "Remote" "--remote=" :reader beady--transient-read-remote)
    ("-s" "Pull conflict strategy" "--strategy=" :choices ("ours" "theirs"))
    ("-f" "Force push" "--force")
    ("-n" "Do not adopt git origin" "--no-adopt")
    ("-y" "Adopt git origin without asking" "--yes")]
   ["Synchronize"
    ("s" "Sync (pull + repair + push)" beady-sync)
    ("F" "Pull from remote" beady-dolt-pull)
    ("P" "Push to remote" beady-dolt-push)
    ("c" "Commit pending changes…" beady-vc-commit)
    ("v" "Version control status" beady-vc-status)]
   ["Remotes & conflicts"
    ("a" "Add remote…" beady-dolt-remote-add)
    ("D" "Remove remote…" beady-dolt-remote-remove)
    ("x" "Show conflicts" beady-conflicts)
    ("O" "Resolve all keeping ours" beady-conflicts-resolve-ours)
    ("T" "Resolve all taking theirs" beady-conflicts-resolve-theirs)
    ("M" "Conclude resolved merge" beady-conflicts-conclude)]]
  (interactive)
  (beady--current-root)
  (transient-setup 'beady-sync-menu))


;;;; Misc

(defun beady-copy-id (ids)
  "Copy the IDs of the targeted beads (IDS) to the kill ring."
  (interactive (list (beady--targets)))
  (let ((text (string-join ids " ")))
    (kill-new text)
    (message "Copied %s" text)))

(defun beady-copy-title (id)
  "Copy the title of bead ID to the kill ring."
  (interactive (list (beady--single-target)))
  (let ((title (alist-get 'title (beady--lookup-issue id))))
    (unless title (user-error "Unknown bead %s" id))
    (kill-new title)
    (message "Copied %s" title)))

(provide 'beady-actions)
;;; beady-actions.el ends here
