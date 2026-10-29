;;; beady-core.el --- Core library for beady  -*- lexical-binding: t; -*-

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

;; Shared infrastructure for the beady libraries: options, faces, the
;; process layer that talks to the `bd' executable, project discovery,
;; status/type metadata and formatting helpers.
;;
;; Every interaction with Beads goes through `beady--run' (synchronous)
;; or `beady--run-async'.  Both always pass `--json' when asked for
;; structured output and never rely on the human readable output of bd.

;;; Code:

(require 'cl-lib)
(require 'parse-time)
(require 'seq)
(require 'subr-x)

;;;; Customization

(defgroup beady nil
  "Browse and manage Beads issues."
  :group 'tools
  :prefix "beady-"
  :link '(url-link :tag "Beads" "https://github.com/gastownhall/beads"))

(defgroup beady-faces nil
  "Faces used by beady."
  :group 'beady
  :group 'faces)

(defcustom beady-executable "bd"
  "Name or absolute file name of the Beads command line tool."
  :type 'string)

(defcustom beady-extra-arguments nil
  "Arguments inserted before the subcommand of every bd invocation.
For example (\"--sandbox\") or (\"--db\" \"/path/to/db\")."
  :type '(repeat string))

(defcustom beady-actor nil
  "Actor name recorded in the Beads audit trail for changes you make.
When nil, bd decides (BEADS_ACTOR, git user.name or $USER)."
  :type '(choice (const :tag "Let bd decide" nil) string))

(defcustom beady-date-format "%Y-%m-%d %H:%M"
  "Format string for absolute timestamps, see `format-time-string'."
  :type 'string)

(defcustom beady-status-icons
  '(("open" . "○") ("in_progress" . "◐") ("blocked" . "●")
    ("deferred" . "❄") ("closed" . "✓") ("pinned" . "✦") ("hooked" . "◇"))
  "Alist mapping status names to the icon displayed next to them.
Statuses that are not listed use `beady-default-status-icon'."
  :type '(alist :key-type string :value-type string))

(defcustom beady-default-status-icon "•"
  "Icon used for statuses missing from `beady-status-icons'."
  :type 'string)

(defcustom beady-status-abbreviations
  '(("in_progress" . "wip") ("deferred" . "defer"))
  "Short labels used for statuses in narrow views.
Statuses missing from this alist keep their full name."
  :type '(alist :key-type string :value-type string))

(defcustom beady-blocked-indicator "⊘"
  "String shown in front of the status of dependency-blocked beads."
  :type 'string)

(defcustom beady-display-buffer-action '(display-buffer-same-window)
  "Action used to display beady buffers opened from outside beady.
See `display-buffer' for the format."
  :type 'sexp)

(defcustom beady-log-commands nil
  "When non-nil, record every bd invocation in the *beady-log* buffer.
Use \\[beady-show-log] to view it."
  :type 'boolean)

(defcustom beady-evil-integration t
  "Whether to install evil keybindings in beady buffers.
When non-nil and evil is loaded, `beady-evil-setup' runs the first
time a beady buffer is created.  When evil is loaded later, the
bindings are installed into the open beady buffers as soon as evil
finishes loading.  Set this to nil to keep the plain Emacs bindings,
or to call `beady-evil-setup' yourself."
  :type 'boolean)

;;;; Faces

(defface beady-id '((t :inherit font-lock-constant-face))
  "Face for bead IDs.")

(defface beady-title '((t :inherit default))
  "Face for bead titles.")

(defface beady-closed '((t :inherit shadow :strike-through t))
  "Face for the titles of closed beads.")

(defface beady-priority-0 '((t :inherit error :weight bold :inverse-video t))
  "Face for priority 0 (critical).")

(defface beady-priority-1 '((t :inherit warning :weight bold))
  "Face for priority 1 (high).")

(defface beady-priority-2 '((t :inherit font-lock-keyword-face))
  "Face for priority 2 (medium).")

(defface beady-priority-3 '((t :inherit shadow))
  "Face for priority 3 (low).")

(defface beady-priority-4 '((t :inherit shadow :slant italic))
  "Face for priority 4 (backlog).")

(defface beady-status-open '((t :inherit success :weight bold))
  "Face for the open status.")

(defface beady-status-in-progress '((t :inherit font-lock-string-face :weight bold))
  "Face for the in_progress status.")

(defface beady-status-blocked '((t :inherit error :weight bold))
  "Face for the blocked status.")

(defface beady-status-deferred '((t :inherit font-lock-doc-face))
  "Face for the deferred status.")

(defface beady-status-closed '((t :inherit shadow))
  "Face for the closed status.")

(defface beady-status-pinned '((t :inherit warning :weight bold))
  "Face for the pinned status.")

(defface beady-status-hooked '((t :inherit font-lock-preprocessor-face :weight bold))
  "Face for the hooked status.")

(defface beady-status-other '((t :inherit font-lock-builtin-face))
  "Face for custom statuses.")

(defface beady-type '((t :inherit font-lock-type-face))
  "Face for issue types.")

(defface beady-type-bug '((t :inherit font-lock-warning-face :weight normal))
  "Face for the bug issue type.")

(defface beady-type-epic '((t :inherit font-lock-type-face :weight bold))
  "Face for the epic issue type.")

(defface beady-assignee '((t :inherit font-lock-variable-name-face))
  "Face for assignees.")

(defface beady-label '((t :inherit font-lock-string-face))
  "Face for labels.")

(defface beady-date '((t :inherit shadow))
  "Face for dates and ages.")

(defface beady-blocked '((t :inherit error))
  "Face for the blocked indicator.")

(defface beady-marked '((t :inherit warning :weight bold))
  "Face for marked beads.")

(defface beady-tree '((t :inherit shadow))
  "Face for tree guides in hierarchical views.")

(defface beady-group-heading '((t :inherit font-lock-keyword-face :weight bold))
  "Face for group headings in the list.")

(defface beady-group-count '((t :inherit shadow))
  "Face for counts in group headings.")

(defface beady-heading '((t :inherit bold :height 1.2))
  "Face for the title in the bead view.")

(defface beady-section-heading '((t :inherit font-lock-keyword-face :weight bold))
  "Face for section headings in the bead view.")

(defface beady-field-name '((t :inherit font-lock-builtin-face))
  "Face for field names in the bead view.")

(defface beady-dim '((t :inherit shadow))
  "Face for secondary information.")

(defface beady-key '((t :inherit help-key-binding))
  "Face for key hints.")

;;;; Errors and logging

(define-error 'beady-error "Beads error" 'user-error)

(defun beady-show-log ()
  "Display the log of bd invocations.
Commands are only logged while `beady-log-commands' is non-nil."
  (interactive)
  (unless beady-log-commands
    (message "Logging is off; set `beady-log-commands' to record commands"))
  (display-buffer (get-buffer-create "*beady-log*")))

(defun beady--command-line (args)
  "Return a shell-like string for running bd with ARGS."
  (mapconcat #'shell-quote-argument (cons beady-executable args) " "))

(defun beady--log (args exit stderr start)
  "Log a bd invocation with ARGS that exited with EXIT.
STDERR is its error output and START the time it was started."
  (when beady-log-commands
    (let ((dir default-directory))
      (with-current-buffer (get-buffer-create "*beady-log*")
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert (format "%s %s  [%s] exit %s, %.2fs\n"
                          (format-time-string "%T")
                          (beady--command-line args)
                          (abbreviate-file-name dir) exit
                          (float-time (time-since start))))
          (unless (string-empty-p (string-trim stderr))
            (insert (replace-regexp-in-string
                     "^" "    " (string-trim-right stderr))
                    "\n")))))))

;;;; Running bd

(defvar json-object-type)
(defvar json-array-type)
(defvar json-key-type)
(defvar json-false)
(defvar json-null)
(declare-function json-read "json" ())

(defun beady--environment ()
  "Return `process-environment' for bd invocations."
  (append '("NO_COLOR=1" "CLICOLOR=0" "BD_NON_INTERACTIVE=1" "PAGER=cat")
          process-environment))

(defun beady--full-args (args)
  "Return ARGS preceded by the user-configured global arguments."
  (append beady-extra-arguments
          (and beady-actor (list (concat "--actor=" beady-actor)))
          args))

(defun beady--parse-json (string)
  "Parse the JSON document in STRING, skipping any leading noise.
Return nil when STRING contains no JSON."
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (when (re-search-forward "^[ \t]*[[{]" nil t)
      (goto-char (1- (match-end 0)))
      (if (and (fboundp 'json-available-p) (json-available-p))
          (json-parse-buffer :object-type 'alist :array-type 'list
                             :null-object nil :false-object nil)
        (require 'json)
        (let ((json-object-type 'alist) (json-array-type 'list)
              (json-key-type 'symbol) (json-false nil) (json-null nil))
          (json-read))))))

(defun beady--json-array-p (value)
  "Return non-nil if VALUE is a parsed JSON array of objects.
Parsed objects are alists too, so an object such as an error payload
must not be mistaken for a list of issues."
  (and (listp value)
       (or (null value) (consp (car-safe (car value))))))

(defun beady--error-message (stderr stdout exit)
  "Build a one line error message from STDERR, STDOUT and EXIT code."
  (let* ((lines (split-string (string-trim stderr) "\n" t "[ \t]+"))
         (msg (car lines)))
    (unless msg
      ;; With --json, bd may report errors as a JSON object on stdout.
      (let ((json (ignore-errors (beady--parse-json stdout))))
        (setq msg (or (and (listp json) (consp (car-safe json))
                           (alist-get 'error json))
                      (car (split-string (string-trim stdout) "\n" t))))))
    (if (or (null msg) (string-empty-p msg))
        (format "bd exited with status %s" exit)
      (replace-regexp-in-string "\\`Error: *" "" msg))))

(defun beady--missing-executable-error ()
  "Signal a `beady-error' explaining why bd could not be started."
  (signal 'beady-error
          (list (if (file-directory-p default-directory)
                    (format "Cannot run %S; install Beads or customize `beady-executable'"
                            beady-executable)
                  (format "Directory %s does not exist anymore"
                          (abbreviate-file-name default-directory))))))

(defun beady--run (args)
  "Run bd with ARGS synchronously in `default-directory'.
Return its standard output as a string.  Signal `beady-error' with a
readable message when bd fails."
  (let ((dir default-directory)
        (errfile (make-temp-file "beady-stderr"))
        (start (current-time)))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory dir)
          (let* ((process-environment (beady--environment))
                 (full (beady--full-args args))
                 (exit (condition-case nil
                           (apply #'process-file beady-executable nil
                                  (list t errfile) nil full)
                         (file-error (beady--missing-executable-error))))
                 (stdout (buffer-string))
                 (stderr (with-temp-buffer
                           (insert-file-contents errfile)
                           (buffer-string))))
            (beady--log full exit stderr start)
            (if (eql exit 0)
                stdout
              (signal 'beady-error
                      (list (beady--error-message stderr stdout exit))))))
      (ignore-errors (delete-file errfile)))))

(defun beady--run-json (args)
  "Run bd with ARGS and `--json', returning the parsed output."
  (beady--parse-json (beady--run (cons "--json" args))))

(defun beady--run-async (args callback &optional errback)
  "Run bd with ARGS asynchronously in `default-directory'.
Call CALLBACK with the standard output when bd succeeds, or ERRBACK
with an error message when it fails.  ERRBACK receives three optional
extra arguments: the exit status, stdout and stderr.  It defaults to
displaying the message.  Return the process object."
  (let* ((out (generate-new-buffer " *beady-out*" t))
         (err (generate-new-buffer " *beady-err*" t))
         (full (beady--full-args args))
         (start (current-time))
         (process-environment (beady--environment))
         (stderr-pipe (make-pipe-process :name "beady-stderr" :buffer err
                                         :noquery t :sentinel #'ignore)))
    (condition-case nil
        (make-process
         :name "beady" :buffer out :stderr stderr-pipe
         :command (cons beady-executable full)
         :connection-type 'pipe :noquery t
         :sentinel
         (lambda (proc _event)
           (unless (process-live-p proc)
             (unwind-protect
                 (progn
                   (accept-process-output stderr-pipe 0)
                   (let ((exit (process-exit-status proc))
                         (stdout (with-current-buffer out (buffer-string)))
                         (stderr (with-current-buffer err (buffer-string))))
                     (with-current-buffer out
                       (beady--log full exit stderr start))
                     (cond
                      ((process-get proc 'beady-cancelled))
                      ((and (eq (process-status proc) 'exit) (eql exit 0))
                       (funcall callback stdout))
                      (t
                       (let ((msg (beady--error-message stderr stdout exit))
                             (fn (or errback
                                     (lambda (m &rest _) (message "beady: %s" m)))))
                         (if (equal (cdr (func-arity fn)) 1)
                             (funcall fn msg)
                           (funcall fn msg exit stdout stderr)))))))
               (kill-buffer out)
               (kill-buffer err)))))
      (file-error
       (kill-buffer out)
       (kill-buffer err)
       (beady--missing-executable-error)))))

(defun beady--cancel-process (proc)
  "Cancel PROC started by `beady--run-async' without running its callbacks."
  (when (processp proc)
    (process-put proc 'beady-cancelled t)
    (when (process-live-p proc)
      (delete-process proc))))

;;;; Projects

(defvar-local beady--root nil
  "Root directory of the Beads project shown in the current buffer.")

(defvar-local beady--refresh-function nil
  "Function that refreshes the current beady buffer.")

(defvar-local beady--targets-function nil
  "Function returning the list of bead IDs the user is acting on.")

(defvar-local beady--lookup-function nil
  "Function taking a bead ID and returning its data known to this buffer.")

(defun beady--beads-dir-p (dir)
  "Return non-nil if DIR contains an initialized .beads directory."
  (let ((beads (expand-file-name ".beads" dir)))
    (and (file-directory-p beads)
         (seq-some (lambda (f) (file-exists-p (expand-file-name f beads)))
                   '("metadata.json" "config.yaml" "beads.db")))))

(defun beady-find-root (&optional directory)
  "Return the root of the Beads project containing DIRECTORY, or nil.
DIRECTORY defaults to `default-directory'.  The root is the directory
containing the .beads directory.  When none is found by walking up
the tree, ask `bd where' (which understands BEADS_DIR, worktrees and
redirects)."
  (let ((dir (file-name-as-directory
              (expand-file-name (or directory default-directory)))))
    (or (when-let* ((found (locate-dominating-file dir #'beady--beads-dir-p)))
          (file-name-as-directory (expand-file-name found)))
        (when (file-directory-p dir)
          (let ((default-directory dir))
            (when-let* ((where (ignore-errors (beady--run-json '("where"))))
                        (path (and (listp where) (alist-get 'path where))))
              (file-name-directory
               (directory-file-name (expand-file-name path)))))))))

(defun beady--project-name (root)
  "Return a short name for the project at ROOT."
  (file-name-nondirectory (directory-file-name root)))

(defun beady--current-root ()
  "Return the project root for the current buffer or signal an error."
  (or beady--root
      (beady-find-root)
      (user-error "Not in a Beads project (no .beads directory found); run `bd init' first")))

(defun beady--buffers (root &optional mode)
  "Return live beady buffers showing ROOT, optionally only those in MODE."
  (seq-filter (lambda (buf)
                (and (equal (buffer-local-value 'beady--root buf) root)
                     (or (null mode)
                         (eq (buffer-local-value 'major-mode buf) mode))))
              (buffer-list)))

(defun beady-refresh-buffers (&optional root)
  "Refresh all beady buffers showing ROOT (default: the current project)."
  (dolist (buf (beady--buffers (or root (beady--current-root))))
    (with-current-buffer buf
      (when beady--refresh-function
        (funcall beady--refresh-function)))))

(defun beady--lookup-issue (id &optional root)
  "Return the data for bead ID known to any beady buffer of ROOT."
  (seq-some (lambda (buf)
              (with-current-buffer buf
                (and beady--lookup-function
                     (funcall beady--lookup-function id))))
            (beady--buffers (or root (beady--current-root)))))

(defvar evil-visual-beginning)
(defvar evil-visual-end)
(declare-function evil-visual-state-p "evil-states" (&optional state))
(declare-function beady-evil-setup "beady-evil" ())

(defun beady--region-bounds ()
  "Return (BEG . END) of the active selection.
In evil's visual state this is the visual range, which covers whole
lines for a line-wise selection."
  (if (and (fboundp 'evil-visual-state-p) (evil-visual-state-p)
           (markerp evil-visual-beginning) (marker-position evil-visual-beginning))
      (cons (marker-position evil-visual-beginning) (marker-position evil-visual-end))
    (cons (region-beginning) (region-end))))

(declare-function evil-exit-visual-state "evil-states" (&optional later buffer))

(defun beady--deactivate-selection ()
  "Deactivate the region, leaving evil's visual state if needed."
  (if (and (fboundp 'evil-visual-state-p) (evil-visual-state-p))
      (evil-exit-visual-state)
    (deactivate-mark)))

(defvar beady--evil-load-hook-installed nil
  "Non-nil once evil bindings wait for evil to be loaded.")

(defun beady--install-evil-bindings ()
  "Install evil bindings in beady buffers when evil is available."
  (when (and beady-evil-integration (featurep 'evil)
             (not (featurep 'beady-evil)))
    (when (require 'beady-evil nil t)
      (beady-evil-setup))))

(defun beady--maybe-setup-evil ()
  "Install evil bindings when `beady-evil-integration' asks for it.
When evil is not loaded yet, arrange for the bindings to be installed
into already open beady buffers as soon as it loads."
  (when beady-evil-integration
    (if (featurep 'evil)
        (beady--install-evil-bindings)
      (unless beady--evil-load-hook-installed
        (setq beady--evil-load-hook-installed t)
        (with-eval-after-load 'evil (beady--install-evil-bindings))))))

;;;; Statuses, types and priorities

(defconst beady--builtin-statuses
  '(("open" . "active") ("in_progress" . "wip") ("blocked" . "wip")
    ("deferred" . "frozen") ("closed" . "done") ("pinned" . "frozen")
    ("hooked" . "wip"))
  "Built-in Beads statuses and their categories.")

(defconst beady--status-order
  '("in_progress" "hooked" "open" "blocked" "deferred" "pinned" "closed")
  "Display order of the built-in statuses.")

(defconst beady--builtin-types
  '("task" "bug" "feature" "chore" "epic" "decision" "spike" "story" "milestone")
  "Built-in Beads issue types.")

(defconst beady--type-order
  '("epic" "milestone" "feature" "story" "bug" "task" "chore" "spike" "decision")
  "Display order of issue types.")

(defconst beady-priority-names
  '((0 . "Critical") (1 . "High") (2 . "Medium") (3 . "Low") (4 . "Backlog"))
  "Names of the Beads priority levels.")

(defvar beady--metadata-cache (make-hash-table :test #'equal)
  "Cache of per-project metadata, keyed by (ROOT . KIND).")

(defun beady--parse-statuses (json)
  "Return an alist of (STATUS . CATEGORY) from `bd statuses' JSON output."
  (let ((result nil))
    (dolist (entry (append (alist-get 'built_in_statuses json)
                           (alist-get 'custom_statuses json)))
      (when-let* ((name (alist-get 'name entry)))
        (push (cons name (alist-get 'category entry)) result)))
    (or (nreverse result) (copy-sequence beady--builtin-statuses))))

(defun beady--parse-status-info (json)
  "Return a list of (NAME ICON CATEGORY DESCRIPTION) from statuses JSON."
  (let ((result nil))
    (dolist (entry (append (alist-get 'built_in_statuses json)
                           (alist-get 'custom_statuses json)))
      (when-let* ((name (alist-get 'name entry)))
        (push (list name (alist-get 'icon entry) (alist-get 'category entry)
                    (alist-get 'description entry))
              result)))
    (nreverse result)))

(defun beady--set-statuses (root json)
  "Store the statuses described by JSON as the statuses of ROOT."
  (puthash (cons root 'statuses) (beady--parse-statuses json)
           beady--metadata-cache)
  (puthash (cons root 'status-info) (beady--parse-status-info json)
           beady--metadata-cache))

(defun beady--statuses (&optional root)
  "Return the alist of (STATUS . CATEGORY) valid in ROOT.
The result includes custom statuses configured in the project."
  (let* ((root (or root (beady--current-root)))
         (key (cons root 'statuses)))
    (or (gethash key beady--metadata-cache)
        (let ((default-directory root))
          (puthash key
                   (condition-case nil
                       (beady--parse-statuses (beady--run-json '("statuses")))
                     (beady-error (copy-sequence beady--builtin-statuses)))
                   beady--metadata-cache)))))

(defun beady--status-info (&optional root)
  "Return the (NAME ICON CATEGORY DESCRIPTION) entries valid in ROOT.
Like `beady--statuses' this fetches `bd statuses' when it is not cached."
  (let* ((root (or root (beady--current-root)))
         (key (cons root 'status-info)))
    (or (gethash key beady--metadata-cache)
        (let ((default-directory root))
          (puthash key
                   (condition-case nil
                       (beady--parse-status-info (beady--run-json '("statuses")))
                     (beady-error nil))
                   beady--metadata-cache)))))

(defun beady--parse-type-info (json)
  "Return an alist of (TYPE . DESCRIPTION) from `bd types' JSON output."
  (append (mapcar (lambda (entry)
                    (cons (alist-get 'name entry)
                          (alist-get 'description entry)))
                  (alist-get 'core_types json))
          (mapcar (lambda (name) (cons name nil))
                  (alist-get 'custom_types json))))

(defun beady--type-info (&optional root)
  "Return the alist of (TYPE . DESCRIPTION) valid in ROOT."
  (let* ((root (or root (beady--current-root)))
         (key (cons root 'type-info)))
    (or (gethash key beady--metadata-cache)
        (let ((default-directory root))
          (puthash key
                   (condition-case nil
                       (beady--parse-type-info (beady--run-json '("types")))
                     (beady-error nil))
                   beady--metadata-cache)))))

(defun beady--set-prefix (root where)
  "Store the issue prefix of ROOT from the `bd where' JSON output WHERE."
  (puthash (cons root 'prefix) (alist-get 'prefix where)
           beady--metadata-cache))

(defun beady--project-prefix (&optional root)
  "Return the cached issue prefix of ROOT, or nil when it is unknown."
  (gethash (cons (or root (beady--current-root)) 'prefix)
           beady--metadata-cache))

(defun beady--short-id (id &optional root)
  "Return ID without the project prefix of ROOT, when there is one."
  (let ((prefix (beady--project-prefix root)))
    (if (and (stringp prefix) (not (string-empty-p prefix))
             (string-prefix-p (concat prefix "-") id))
        (substring id (1+ (length prefix)))
      id)))

(defun beady--types (&optional root)
  "Return the list of issue types valid in ROOT."
  (let* ((root (or root (beady--current-root)))
         (key (cons root 'types)))
    (or (gethash key beady--metadata-cache)
        (let ((default-directory root))
          (puthash key
                   (condition-case nil
                       (let ((json (beady--run-json '("types"))))
                         (delete-dups
                          (append (mapcar (lambda (e) (alist-get 'name e))
                                          (alist-get 'core_types json))
                                  (alist-get 'custom_types json))))
                     (beady-error (copy-sequence beady--builtin-types)))
                   beady--metadata-cache)))))

(defun beady--forget-metadata (root)
  "Forget the cached metadata of ROOT."
  (dolist (kind '(statuses status-info types type-info prefix))
    (remhash (cons root kind) beady--metadata-cache)))

(defun beady--status-category (status statuses)
  "Return the category of STATUS according to the STATUSES alist."
  (or (cdr (assoc status statuses))
      (cdr (assoc status beady--builtin-statuses))))

(defun beady--status-done-p (status statuses)
  "Return non-nil if STATUS counts as done according to STATUSES."
  (or (equal status "closed")
      (equal (beady--status-category status statuses) "done")))

(defun beady--ordered-statuses (statuses)
  "Return the names in STATUSES in workflow order.
Custom statuses are placed next to the built-in statuses of the same
category."
  (let ((anchors '(("wip" . "hooked") ("active" . "open")
                   ("frozen" . "pinned") ("done" . "closed")))
        (order (copy-sequence beady--status-order))
        (last-inserted nil))
    (dolist (entry statuses)
      (unless (member (car entry) order)
        (let* ((anchor (or (cdr (assoc (cdr entry) anchors)) "pinned"))
               (cell (or (cdr (assoc anchor last-inserted))
                         (member anchor order))))
          (setcdr cell (cons (car entry) (cdr cell)))
          (setf (alist-get anchor last-inserted nil nil #'equal) (cdr cell)))))
    order))

(defun beady--rank (item order)
  "Return the position of ITEM in ORDER, or a large number."
  (or (seq-position order item) (+ (length order) 1)))

(defun beady--priority-name (priority)
  "Return the name of PRIORITY, a number."
  (or (cdr (assq priority beady-priority-names)) "Unknown"))

;;;; Issue accessors

(defsubst beady--id (issue)
  "Return the ID of ISSUE."
  (alist-get 'id issue))

(defun beady--issue-parent (issue)
  "Return the ID of ISSUE's parent, or nil."
  (or (alist-get 'parent issue)
      (cl-loop for dep in (alist-get 'dependencies issue)
               when (equal (or (alist-get 'type dep)
                               (alist-get 'dependency_type dep))
                           "parent-child")
               return (or (alist-get 'depends_on_id dep)
                          (alist-get 'id dep)))))

;;;; Time

(defvar beady--time-cache (make-hash-table :test #'equal)
  "Cache of parsed timestamps.")

(defun beady--time (string)
  "Parse the RFC 3339 timestamp STRING into a Lisp time, or return nil."
  (when (and (stringp string) (not (string-empty-p string))
             (not (string-prefix-p "0001-" string)))
    (when (> (hash-table-count beady--time-cache) 20000)
      (clrhash beady--time-cache))
    (let ((cached (gethash string beady--time-cache 'none)))
      (if (not (eq cached 'none))
          cached
        (puthash string (ignore-errors (parse-iso8601-time-string string))
                 beady--time-cache)))))

(defun beady--format-age (time &optional now)
  "Return a compact description of how long ago TIME was, e.g. \"3d\".
NOW defaults to the current time.  Future times are prefixed with \"in \"."
  (when time
    (let* ((delta (float-time (time-subtract (or now (current-time)) time)))
           (future (< delta 0))
           (secs (abs delta))
           (text (cond ((< secs 60) "now")
                       ((< secs 3600) (format "%dm" (/ secs 60)))
                       ((< secs 86400) (format "%dh" (/ secs 3600)))
                       ((< secs (* 14 86400)) (format "%dd" (/ secs 86400)))
                       ((< secs (* 60 86400)) (format "%dw" (/ secs 604800)))
                       ((< secs (* 365 86400)) (format "%dmo" (/ secs 2592000)))
                       (t (format "%dy" (/ secs 31536000))))))
      (if (and future (not (equal text "now"))) (concat "in " text) text))))

(defun beady--format-date (time)
  "Format TIME according to `beady-date-format', or return nil."
  (and time (format-time-string beady-date-format time)))

;;;; Formatting

(defun beady--pad (string width)
  "Truncate or pad STRING to WIDTH display columns.
When WIDTH is nil, return STRING unchanged."
  (if width
      (truncate-string-to-width (or string "") width nil ?\s "…")
    (or string "")))

(defun beady--status-icon (status)
  "Return the icon for STATUS."
  (or (cdr (assoc status beady-status-icons)) beady-default-status-icon))

(defun beady--status-label (status)
  "Return the short display label of STATUS."
  (or (cdr (assoc status beady-status-abbreviations)) status))

(defun beady--status-face (status)
  "Return the face for STATUS."
  (pcase status
    ("open" 'beady-status-open)
    ("in_progress" 'beady-status-in-progress)
    ("blocked" 'beady-status-blocked)
    ("deferred" 'beady-status-deferred)
    ("closed" 'beady-status-closed)
    ("pinned" 'beady-status-pinned)
    ("hooked" 'beady-status-hooked)
    (_ 'beady-status-other)))

(defun beady--format-status (status)
  "Return STATUS with its icon, propertized."
  (propertize (concat (beady--status-icon status) " " (or status "?"))
              'face (beady--status-face status)))

(defun beady--priority-face (priority)
  "Return the face for PRIORITY."
  (pcase priority
    (0 'beady-priority-0) (1 'beady-priority-1) (2 'beady-priority-2)
    (3 'beady-priority-3) (_ 'beady-priority-4)))

(defun beady--format-priority (priority)
  "Return PRIORITY formatted as \"P<n>\", propertized."
  (propertize (if (numberp priority) (format "P%d" priority) "P?")
              'face (beady--priority-face priority)))

(defun beady--type-face (type)
  "Return the face for issue TYPE."
  (pcase type
    ("bug" 'beady-type-bug)
    ("epic" 'beady-type-epic)
    (_ 'beady-type)))

(defun beady--format-type (type)
  "Return issue TYPE, propertized."
  (propertize (or type "") 'face (beady--type-face type)))

(defun beady--format-labels (labels)
  "Return LABELS as propertized #tags separated by spaces."
  (mapconcat (lambda (label) (propertize (format "#%s" label) 'face 'beady-label))
             labels " "))

(defun beady--format-assignee (assignee)
  "Return ASSIGNEE as a propertized \"@name\", or the empty string."
  (if (and (stringp assignee) (not (string-empty-p assignee)))
      (propertize (concat "@" assignee) 'face 'beady-assignee)
    ""))

(defun beady--key-score (key)
  "Return a sort score for KEY: shorter and printable keys score lower."
  (+ (* 2 (length key))
     (let ((event (aref key 0)))
       (if (and (characterp event) (<= 33 event 126)) 0 1))))

(defun beady--key-for (command)
  "Return the best key that runs COMMAND in the current buffer, or nil.
Short, printable keys are preferred.  Bindings shadowed by other
keymaps (e.g. evil states) are ignored."
  (let ((best nil)
        ;; Ignore keymaps of an active transient menu.
        (overriding-terminal-local-map nil)
        (overriding-local-map nil))
    (dolist (key (where-is-internal command nil nil t))
      (when (and (eq (key-binding key t) command)
                 (not (memq (aref key 0) '(menu-bar tool-bar remap)))
                 (or (null best) (< (beady--key-score key) (beady--key-score best))))
        (setq best key)))
    (and best (key-description best))))

(defun beady--restore-window-start (window offset)
  "Make WINDOW show point OFFSET lines below its start, if useful.
When everything above point fits in WINDOW, show the buffer from the
top instead, so that headers stay visible."
  (set-window-start window
                    (if (< (count-lines (point-min) (point)) (window-body-height window))
                        (point-min)
                      (save-excursion (forward-line (- offset)) (point)))
                    t))

(defun beady--hints (pairs)
  "Return a hint string for PAIRS of (COMMAND . DESCRIPTION).
Commands without a key binding in the current buffer are skipped."
  (mapconcat #'identity
             (delq nil
                   (mapcar (lambda (pair)
                             (when-let* ((key (beady--key-for (car pair))))
                               (concat (propertize key 'face 'beady-key)
                                       " " (cdr pair))))
                           pairs))
             "  "))

(provide 'beady-core)
;;; beady-core.el ends here
