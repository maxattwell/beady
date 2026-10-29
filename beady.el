;;; beady.el --- Browse and manage Beads issues  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Max Attwell <max.attwell@hotmail.com>
;; Maintainer: Max Attwell <max.attwell@hotmail.com>
;; Assisted-by: pi:claude-opus-5.5
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (transient "0.4.1"))
;; Keywords: tools, convenience
;; URL: https://github.com/maxattwell/beady

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

;; beady is an Emacs interface to Beads (https://github.com/gastownhall/beads),
;; the distributed, dependency-aware issue tracker for AI agents.  It
;; talks to the `bd' command line tool, which must be installed.
;;
;; M-x beady opens a read-only list of the beads of the current project.
;; From there:
;;
;;   ?    menu of all commands
;;   v    search, filter, sort and group the list (a transient menu that
;;        shows the current value of every option)
;;   /    live search
;;   RET  show the bead at point
;;   s    change the status of the bead at point (or of the marked beads)
;;
;; Evil users get vim-style bindings automatically (see
;; `beady-evil-integration' and `beady-evil-setup').
;;
;; See the README for the full list of commands and options.

;;; Code:

(require 'beady-core)
(require 'beady-actions)
(require 'beady-show)
(require 'beady-list)

(defconst beady-version "0.1.0"
  "Version of beady.")

;;;###autoload
(defun beady (&optional directory)
  "Show the beads of the Beads project containing DIRECTORY.
DIRECTORY defaults to `default-directory'.  With a prefix argument, or
when no project is found, ask for the directory."
  (interactive
   (list (and current-prefix-arg
              (read-directory-name "Beads project: "))))
  (let ((root (beady-find-root directory)))
    (while (and (not root) (called-interactively-p 'any))
      (let ((dir (read-directory-name
                  (format "No Beads project in %s; directory: "
                          (abbreviate-file-name (or directory default-directory))))))
        (setq root (beady-find-root dir)
              directory dir)))
    (unless root
      (user-error "No Beads project in %s; run `bd init' there first"
                  (abbreviate-file-name (or directory default-directory))))
    (beady-list root)))

;;;###autoload (autoload 'beady-create-menu "beady" "Create a new bead." t)
;;;###autoload (autoload 'beady-show-issue "beady" "Show a bead by ID." t)
;;;###autoload (autoload 'beady-sync "beady" "Synchronize the current Beads project with its Dolt remote." t)
;;;###autoload (autoload 'beady-sync-menu "beady" "Synchronize and manage the Dolt database of the current Beads project." t)

(provide 'beady)
;;; beady.el ends here
