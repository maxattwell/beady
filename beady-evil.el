;;; beady-evil.el --- Evil keybindings for beady  -*- lexical-binding: t; -*-

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

;; Vim-style bindings for beady buffers, following the conventions of
;; evil-collection: j/k move, RET opens, gr refreshes, q quits, za/zo/zc
;; fold groups, C-o/C-i walk the history, yy copies, ZZ/ZQ finish or
;; cancel a compose buffer.  Single-letter beady actions (s status,
;; x close, v view menu, / search, ? all commands, ...) keep the same
;; keys as in Emacs state so the menus double as a cheat sheet.
;;
;; The bindings are installed automatically the first time a beady
;; buffer is opened while evil is loaded, unless
;; `beady-evil-integration' is nil.  To install them yourself:
;;
;;   (with-eval-after-load 'evil
;;     (require 'beady-evil)
;;     (beady-evil-setup))

;;; Code:

(require 'beady)
(require 'evil)
(require 'transient)

(defcustom beady-evil-bind-escape-in-transient t
  "When non-nil, make ESC close transient menus.
This binds <escape> in `transient-map' unless something else already
does, which affects all transient menus (Doom Emacs does the same)."
  :type 'boolean
  :group 'beady)

(defconst beady-evil--list-bindings
  '(("RET" . beady-list-show)
    ("go" . beady-list-show-other-window)
    ("gO" . beady-list-display)
    ("C-j" . beady-list-next)
    ("C-k" . beady-list-previous)
    ("gj" . beady-list-next-group)
    ("gk" . beady-list-previous-group)
    ("]]" . beady-list-next-group)
    ("[[" . beady-list-previous-group)
    ("TAB" . beady-list-toggle-group)
    ("<backtab>" . beady-list-toggle-all-groups)
    ("za" . beady-list-toggle-group)
    ("zo" . beady-list-expand-group)
    ("zc" . beady-list-collapse-group)
    ("zR" . beady-list-expand-all)
    ("zM" . beady-list-collapse-all)
    ("gr" . beady-list-refresh)
    ("/" . beady-list-search)
    ("v" . beady-list-view-menu)
    ("?" . beady-list-dispatch)
    ("g?" . describe-mode)
    ("T" . beady-list-toggle-tree)
    ("F" . beady-list-follow-mode)
    ("m" . beady-list-mark)
    ("u" . beady-list-unmark)
    ("U" . beady-list-unmark-all)
    ("t" . beady-list-toggle-marks)
    ("s" . beady-status-menu)
    ("x" . beady-close)
    ("P" . beady-priority-menu)
    ("a" . beady-assign)
    ("L" . beady-labels-menu)
    ("C" . beady-add-comment)
    ("e" . beady-edit-menu)
    ("c" . beady-create-menu)
    ("S" . beady-sync-menu)
    ("yy" . beady-copy-id)
    ("yt" . beady-copy-title)
    ("q" . quit-window)
    ("ZZ" . quit-window)
    ("ZQ" . quit-window))
  "Normal state bindings of `beady-list-mode'.")

(defconst beady-evil--list-visual-bindings
  '(("m" . beady-list-mark)
    ("u" . beady-list-unmark)
    ("s" . beady-status-menu)
    ("x" . beady-close)
    ("P" . beady-priority-menu)
    ("a" . beady-assign)
    ("L" . beady-labels-menu)
    ("C" . beady-add-comment)
    ("e" . beady-edit-menu)
    ("y" . beady-copy-id))
  "Visual state bindings of `beady-list-mode'; they act on the selection.")

(defconst beady-evil--show-bindings
  '(("RET" . push-button)
    ("<tab>" . forward-button)
    ("<backtab>" . backward-button)
    ("g]" . forward-button)
    ("g[" . backward-button)
    ("C-o" . beady-show-back)
    ("C-i" . beady-show-forward)
    ("<" . beady-show-back)
    (">" . beady-show-forward)
    ("gj" . beady-show-next)
    ("gk" . beady-show-previous)
    ("C-j" . beady-show-next)
    ("C-k" . beady-show-previous)
    ("]]" . beady-show-next-section)
    ("[[" . beady-show-previous-section)
    ("^" . beady-show-parent)
    ("gu" . beady-show-parent)
    ("gl" . beady-show-goto-list)
    ("gr" . beady-show-refresh)
    ("?" . beady-show-dispatch)
    ("g?" . describe-mode)
    ("s" . beady-status-menu)
    ("x" . beady-close)
    ("P" . beady-priority-menu)
    ("a" . beady-assign)
    ("L" . beady-labels-menu)
    ("C" . beady-add-comment)
    ("e" . beady-edit-menu)
    ("c" . beady-create-menu)
    ("S" . beady-sync-menu)
    ("yy" . beady-copy-id)
    ("yt" . beady-copy-title)
    ("q" . quit-window)
    ("ZZ" . quit-window)
    ("ZQ" . quit-window))
  "Normal state bindings of `beady-show-mode'.")

(defconst beady-evil--compose-bindings
  '(("ZZ" . beady-compose-finish)
    ("ZQ" . beady-compose-cancel))
  "Normal state bindings of `beady-compose-mode'.")

(defun beady-evil--define (state map bindings)
  "Bind BINDINGS, an alist of (KEY . COMMAND), in MAP for evil STATE."
  (dolist (binding bindings)
    (evil-define-key* state map (kbd (car binding)) (cdr binding))))

(defun beady-evil--compose-setup ()
  "Choose the evil state of a new compose buffer.
Empty buffers start in insert state, others in normal state."
  (evil-normalize-keymaps)
  (if (= (buffer-size) 0)
      (evil-insert-state)
    (evil-normal-state)))

;;;###autoload
(defun beady-evil-setup ()
  "Install evil keybindings for beady buffers.
List and bead buffers start in normal state with vim-style motions;
press ? in either for a menu of all commands."
  (interactive)
  (evil-set-initial-state 'beady-list-mode 'normal)
  (evil-set-initial-state 'beady-show-mode 'normal)
  (beady-evil--define 'normal beady-list-mode-map beady-evil--list-bindings)
  (beady-evil--define 'visual beady-list-mode-map beady-evil--list-visual-bindings)
  (beady-evil--define 'normal beady-show-mode-map beady-evil--show-bindings)
  (beady-evil--define 'normal beady-compose-mode-map beady-evil--compose-bindings)
  (add-hook 'beady-compose-hook #'beady-evil--compose-setup)
  (when (and beady-evil-bind-escape-in-transient
             (not (lookup-key transient-map [escape])))
    (define-key transient-map [escape] #'transient-quit-one))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (or (derived-mode-p 'beady-list-mode 'beady-show-mode)
                (bound-and-true-p beady-compose-mode))
        (evil-normalize-keymaps)))))

(provide 'beady-evil)
;;; beady-evil.el ends here
