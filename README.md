# beady — an Emacs interface for Beads

`beady` lets you browse and manage [Beads](https://github.com/gastownhall/beads)
issues from Emacs. Beads is the distributed, dependency-aware issue tracker
for AI agents. beady is meant to replace the web UI
([beads-ui](https://github.com/mantoni/beads-ui)) and the terminal UI
([beads_viewer](https://github.com/Dicklesworthstone/beads_viewer)) for people
who live in Emacs. It works with plain Emacs keys and with evil.

```
beads-sandbox  9 of 9 beads   ○ open 8  ✓ closed 1
Show all   Sort priority   Group board lanes
? commands  v filter/sort/group  / search  RET open  s status  c new

  ID    Pri Status   Title
──────────────────────────
▾ Blocked (2)
  egi.1 P1  ⊘ open   Implement OAuth2 login flow [3c] [dep:1]  feature  @alice  56m  #backend #security
  egi.2 P3  ⊘ open   Write auth docs edit [dep:1]  chore  56m  #backend #docs #security

▾ Ready (6)
  fmb   P0  ○ open   Session token expires too early [2c]  bug  56m  #backend #urgent
  2lo   P2  ○ open   Decide on token storage  decision  56m
  ...

▾ Closed (1)
  8dz   P2  ✓ closed Add dark mode to settings page  feature  23h  #frontend #ui
```

The compact default layout shows short IDs (`egi.1`), short status labels
(`◐ wip` means `in_progress`) and puts type, assignee, age and labels in a
trailer after the title. Every field is still there: `W` in the view menu
(or `M-x beady-list-toggle-column-profile`) switches to the wide table, and
`h` opens a legend of the status icons and types. `⊘` in the status column
marks beads blocked by an open dependency; `[3c]` and `[dep:1]` are the
comment and dependency counts; labels and assignees are shown as `#tag` and
`@name`.

## Features

- **A read-only list of all beads.** It loads asynchronously and has a
  summary line with counts per status. The compact default layout uses short
  IDs and status labels with a trailer of type, assignee, age and labels;
  the wide table is one command away. Columns are aligned by a full-width
  table header with a rule line and stay put while you filter. Comment and
  dependency counts are shown next to the title, labels as `#tag` and
  assignees as `@name`. `W` switches layouts and `h` shows a legend of the
  status and type symbols.
- **One transient menu (`v`)** for every search, filter, sort and group
  option. Each option shows its current value, and every change applies
  immediately while the menu stays open.
  - **Search:** live text search that updates as you type, or any
    [`bd query`](https://github.com/gastownhall/beads) expression
    (e.g. `type=bug AND priority<=1 AND updated>7d`).
  - **Filter:** by status (open, ready, blocked, closed or all), explicit
    statuses, type, priority, label, assignee (including unassigned), or
    epic/parent subtree.
  - **Sort:** by priority, last update, creation, close date, due date, ID,
    title, status, type or assignee, in either direction.
  - **Group:** by status, *board lanes* (Blocked / Ready / In progress /
    Deferred / Closed, like the kanban boards of beads-ui and bv), priority,
    type, assignee, label or epic (with "n/m closed" progress). Groups fold.
  - **Tree view:** children are indented under their parents with tree
    guides.
- **Bead view** (`RET`). It shows fields, Markdown-rendered description,
  design, acceptance criteria and notes, the parent, children, dependencies,
  dependents and related beads, epic progress and comments. Bead IDs are
  links, with back/forward history. `n`/`p` step through the list without
  leaving the view. Follow mode (`F`) previews the bead at point while you
  move through the list.
- **Status changes** (`s`): open, in progress, blocked, deferred (with an
  optional date), closed (with an optional reason), any custom status, and
  claim/unclaim. "Open" does the right thing for each bead: closed ones are
  reopened, deferred ones undeferred. If bd refuses a change and suggests
  `--force` (closing an epic with open children, or reassigning a bead
  someone else has claimed), beady shows the reason and asks whether to
  force it.
- **Other edits:** priority, assignee, labels, title, description, design,
  acceptance criteria, notes, type, due date, estimate, external ref, parent
  and blockers. Comments and longer text are written in a Markdown compose
  buffer. New beads can be created with type, priority, labels, parent and
  so on.
- **Bulk actions:** every change applies to the marked beads (`m`), to the
  region or evil visual selection, or else to the bead at point.
- **Evil support** follows the conventions of evil-collection (`gr`, `za`,
  `C-o`, `yy`, `ZZ`, …). It is set up automatically when evil is loaded,
  in either load order, and the `?` dispatch menu shows the keys of the
  active editing state (for example `go`/`gO` under evil normal state).
- **Discoverability:** `?` opens a menu of every command in any beady buffer.
  Key hints in the summary and the bead view header always show the keys of
  the current editing state.
- Talks to bd only through its `--json` output. Every change refreshes all
  beady buffers of the project. Auto-refresh is optional.

## Requirements

- Emacs 29.1 or newer.
- [transient](https://github.com/magit/transient), which is built into
  Emacs 29+.
- The Beads CLI `bd` on your `PATH`, or set `beady-executable`. Tested with
  bd 1.3.0.
- Optional: [markdown-mode](https://github.com/jrblevin/markdown-mode) to
  render Markdown and to edit text in GFM mode.
- Optional: [evil](https://github.com/emacs-evil/evil).

## Installation

Byte-compile the package once for speed: run `make compile`, or
`M-x byte-recompile-directory` on the package directory.

### Doom Emacs

The simplest setup for a local checkout goes in `~/.config/doom/config.el`:

```elisp
(use-package! beady
  :load-path "~/path/to/beady"
  :commands (beady beady-show-issue beady-create-menu)
  :init
  (map! :leader :desc "Beads" "o B" #'beady))
```

Restart Emacs (no `doom sync` is needed for a `:load-path` package). Open
beady with `SPC o B`. The evil bindings are installed automatically.

If the package lives in a git repository, you can let straight manage it
instead. Put this in `packages.el`, drop the `:load-path` line above, and
run `doom sync`:

```elisp
(package! beady :recipe (:local-repo "/path/to/beady" :files ("*.el")))
```

Doom treats buffers whose names start with `*` as "unreal", so they are
skipped by some buffer-switching commands. To treat beady buffers like magit
buffers, add:

```elisp
(add-hook 'doom-real-buffer-functions
          (lambda (buf)
            (with-current-buffer buf
              (derived-mode-p 'beady-list-mode 'beady-show-mode))))
```

### use-package

```elisp
(use-package beady
  :load-path "/path/to/beady"
  :commands (beady beady-show-issue beady-create-menu)
  :bind ("C-c b" . beady))
```

### straight.el (from a git checkout)

```elisp
(straight-use-package
 '(beady :local-repo "/path/to/beady" :files ("*.el")))
```

### Manually

```elisp
(add-to-list 'load-path "/path/to/beady")
(require 'beady)
(global-set-key (kbd "C-c b") #'beady)
```

## Usage

Run `M-x beady` in any file or directory inside a project that has a
`.beads` directory. With a prefix argument, or when no project is found,
beady asks for the directory. Each project gets its own list buffer.

Other entry points:

- `M-x beady-show-issue` opens a bead by ID, with completion.
- `M-x beady-create-menu` creates a bead.

### The list

| Emacs           | Evil                  | Command                                        |
|-----------------|-----------------------|------------------------------------------------|
| `?`             | `?`                   | Menu of all commands                           |
| `v`             | `v`                   | **View menu**: search / filter / sort / group  |
| `/`             | `/`                   | Live search                                    |
| `RET`           | `RET`                 | Show the bead (on a group heading: fold it)    |
| `o` / `C-o`     | `go` / `gO`           | Show in other window / display without select  |
| `n` / `p`       | `j` / `k`, `C-j`/`C-k`| Next / previous bead                           |
| `M-n` / `M-p`   | `gj`/`gk`, `]]`/`[[`  | Next / previous group                          |
| `TAB`           | `TAB`, `za`           | Fold or unfold the group                       |
| `S-TAB`         | `S-TAB`, `zM` / `zR`  | Fold / unfold all groups                       |
| —               | `zo` / `zc`           | Unfold / fold the group                        |
| `T`             | `T`                   | Toggle the tree view                           |
| `F`             | `F`                   | Toggle follow mode                             |
| `g`             | `gr`                  | Refresh                                        |
| `m` / `u` / `U` | `m` / `u` / `U`       | Mark / unmark / unmark all                     |
| `t`             | `t`                   | Toggle all marks                               |
| `s`             | `s`                   | **Status menu**                                |
| `x`             | `x`                   | Close (asks for an optional reason)            |
| `P`             | `P`                   | Priority menu (`0`–`4`)                        |
| `a`             | `a`                   | Assign (empty input unassigns)                 |
| `L`             | `L`                   | Labels menu (add / remove / set)               |
| `e`             | `e`                   | Edit menu (text fields, type, dates, relations)|
| `C`             | `C`                   | Comment                                        |
| `c`             | `c`                   | Create menu                                    |
| `w`             | `yy` / `yt`           | Copy ID / copy title                           |
| `q`             | `q`, `ZZ`             | Quit window                                    |

In evil visual state, `m`, `u`, `s`, `x`, `P`, `a`, `L`, `e`, `C` and `y` act
on the selected lines. For example, `Vjjsc` closes three beads.

### The view menu (`v`)

```
Search           Show                  Filter by
 / Text           o Open (not closed)   fs Status       ft Type     fp Priority
 Q bd query       r Ready to work       fl Label        fa Assignee fe Epic/parent
                  b Blocked             fx Reset filters
                  c Closed
                  a All
Sort by         Group by        Display
 sp Priority    si ID           gn Nothing     gt Type        T Tree of children
 su Last update st Title        gs Status      ga Assignee    F Follow point
 sc Creation    ss Status       gb Board lanes gl Label       W Wide columns
 sC Close date  sT Type         gp Priority    ge Epic/parent h Legend of icons
 sd Due date    sa Assignee                                   R Reset everything
                sr Reverse order                              q Done
```

The active choices are highlighted and filter values are shown inline. The
menu stays open, so you can combine several changes and watch the list
update behind it. Press `q` (or `C-g`, or `ESC` with evil) when you are
done.

"Ready" uses the same meaning as `bd ready`: an active status, no open
blockers, and not deferred to a future date. "Blocked" covers both the
`blocked` status and beads with open blocking dependencies.

### Legend (`h`)

`h` in the view menu (or `M-x beady-list-show-legend`) opens a read-only
legend of every status and type of the project, with the icon, the short
label and bd's description. The list itself uses these symbols:

| Symbol | Status        |
|--------|---------------|
| `○`    | open          |
| `◐`    | in_progress (`wip` in the list) |
| `⊘`    | blocked by an open dependency (any status) |
| `●`    | blocked       |
| `❄`    | deferred (`defer`) |
| `✦`    | pinned        |
| `◇`    | hooked        |
| `✓`    | closed        |

The summary line counts each status that occurs in the project, e.g.
`○ open 8  ✓ closed 1`, and the status cell has the full name as a
tooltip. Types are shown as names (`bug`, `feature`, …); bd has no type
icons, so beady does not invent any.

### The bead view

| Emacs        | Evil                      | Command                         |
|--------------|---------------------------|---------------------------------|
| `?`          | `?`                       | Menu of all commands            |
| `RET`        | `RET`                     | Follow the link at point        |
| `TAB`/`S-TAB`| `TAB`/`S-TAB`, `g]`/`g[`  | Next / previous link            |
| `l` / `r`    | `C-o` / `C-i`, `<` / `>`  | Back / forward in history       |
| `n` / `p`    | `gj`/`gk`, `C-j`/`C-k`    | Next / previous bead of the list|
| `M-n`/`M-p`  | `]]` / `[[`               | Next / previous section         |
| `^`          | `^`, `gu`                 | Go to the parent                |
| `j`          | `gl`                      | Jump to the bead in the list    |
| `g`          | `gr`                      | Refresh                         |
| `s` `x` `P` `a` `L` `e` `C` `c` | same       | Same actions as in the list     |
| `w`          | `yy` / `yt`               | Copy ID / title                 |
| `q`          | `q`, `ZZ`                 | Quit window                     |

### Compose buffers

Comments, descriptions and other long text are edited in a small buffer.
It uses `gfm-mode` when markdown-mode is installed. Finish with `C-c C-c`
(evil: `ZZ`) or cancel with `C-c C-k` (evil: `ZQ`). If bd rejects the
change, the buffer stays open so nothing is lost. Evil users start in
insert state when the buffer is empty.

To create a bead with a description, use `c C` in the create menu. The
first line of the buffer is the title and the rest is the description.

## Evil

When `beady-evil-integration` is non-nil (the default) and evil is loaded,
`beady-evil-setup` runs the first time a beady buffer opens. If evil is
loaded later, the bindings are installed into beady buffers that are
already open. It:

- starts list and bead buffers in normal state;
- adds the bindings shown above, following evil-collection conventions;
- keeps single-letter beady actions on the same keys as in Emacs state and
  makes the `?` menu show the keys of the active state (for example
  `go`/`gO` under evil normal state), so both work as a cheat sheet;
- binds `ESC` to close transient menus, unless something else (e.g. Doom)
  already does. Set `beady-evil-bind-escape-in-transient` to nil to opt out.

To install the bindings yourself, set `beady-evil-integration` to nil and
call:

```elisp
(with-eval-after-load 'evil
  (require 'beady-evil)
  (beady-evil-setup))
```

beady's bindings are buffer-local, so they take precedence over global
evil-state bindings such as `s` for avy or `f`/`t` for easymotion.

## Customization

`M-x customize-group RET beady` lists every option. The main ones are:

| Option                             | Default                       | Meaning                                            |
|------------------------------------|-------------------------------|----------------------------------------------------|
| `beady-executable`                 | `"bd"`                        | The bd program                                     |
| `beady-extra-arguments`            | `nil`                         | Arguments for every bd call, e.g. `("--sandbox")`  |
| `beady-actor`                      | `nil`                         | Actor recorded in the audit trail                  |
| `beady-list-default-filter`        | `(:status open)`              | Initial filter                                     |
| `beady-list-default-sort`          | `priority`                    | Initial sort field                                 |
| `beady-list-default-group`         | `nil`                         | Initial grouping, e.g. `lane` for a board          |
| `beady-list-default-tree`          | `nil`                         | Start in tree view                                 |
| `beady-list-columns`               | `(mark id priority status title type assignee age labels)` | Columns and their order; after `title` they become an unpadded trailer |
| `beady-list-id-style`              | `short`                       | `full`, `short` (strip project prefix) or `hidden` |
| `beady-list-status-style`          | `short`                       | `full`, `short` labels or `icon` only              |
| `beady-status-abbreviations`       | `(("in_progress" . "wip") ("deferred" . "defer"))` | Short status labels for the list |
| `beady-list-search-fields`         | `(id title description labels assignee)` | Fields searched by `/`                 |
| `beady-list-show-column-header`    | `t`                           | Show the table header and rule in the list buffer  |
| `beady-list-auto-refresh-interval` | `nil`                         | Seconds between refreshes of visible lists         |
| `beady-show-reuse-buffer`          | `t`                           | One bead buffer per project, with history          |
| `beady-show-fontify-markdown`      | `t`                           | Render Markdown in the bead view                   |
| `beady-status-icons`               | bd's icons                    | Icons per status                                   |
| `beady-display-buffer-action`      | same window                   | How beady buffers are displayed                    |
| `beady-evil-integration`           | `t`                           | Install evil bindings automatically                |
| `beady-log-commands`               | `nil`                         | Log every bd call to `*beady-log*`                 |

Every face is in the `beady-faces` group.

## How it works

- Opening or refreshing a list runs `bd list --all --limit 0`, `bd blocked`,
  `bd statuses` and `bd where` (for the project prefix used by short IDs)
  in parallel. With a query filter it also runs
  `bd query`. All of them use `--json` and run asynchronously, so Emacs stays
  responsive.
- After that, filtering, searching, sorting, grouping and the tree view are
  computed locally, so changing the view needs no extra bd calls. A list of
  2000 beads redraws in well under 100 ms.
- The bead view appears at once from the data already loaded. Comments and
  dependents are then filled in by `bd show --include-comments
  --include-dependents`.
- Changes use bd's own commands (`update`, `close`, `reopen`, `defer`,
  `undefer`, `comment`, `dep`, …). Afterwards every beady buffer of the
  project refreshes, and point stays on the same bead.
- Custom statuses (`status.custom`) and custom types (`types.custom`) are
  read from bd and work in filters, groups and menus.
- The package is called *beady* because the `beads-` prefix belongs to an
  older, unmaintained beads.el. The different name means both can be
  installed without conflicts.

## Development

```sh
make compile   # byte-compile, warnings are errors
make test      # ERT suite; integration tests need bd, evil tests need evil
make lint      # checkdoc and package-lint
```

To test the optional integrations, pass extra load paths, for example:

```sh
make test LOAD_PATH="-L ~/.emacs.d/elpa/evil-1.15.0 -L ~/.emacs.d/elpa/goto-chg-1.7.5 -L ~/.emacs.d/elpa/markdown-mode-2.7"
```

The integration tests create a temporary Beads database. They exercise every
kind of change against the real `bd` and check the results with
`bd show --json`.

## Provenance

beady was developed with AI assistance: the `pi` coding harness, mainly with
Claude Opus 5.5.  Each source file records this in its header as
`Assisted-by: pi:claude-opus-5.5`.
