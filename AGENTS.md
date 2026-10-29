# AGENTS.md — `beady`

`beady` is an Emacs interface for [Beads (`bd`)](https://github.com/gastownhall/beads), the distributed, dependency-aware issue tracker for AI agents. Requires Emacs 29.1+ and `transient` (0.4.1+); optional integrations exist for `evil` and `markdown-mode`.

## Architecture & Module Map

- **`beady.el`** — Package entry point and autoloaded commands (`beady`, `beady-show-issue`, `beady-create-menu`).
- **`beady-core.el`** — Customization options, faces, project root discovery (`.beads`), status/type metadata caches, formatting helpers, and process execution (`beady--run`, `beady--run-json`, `beady--run-async`).
- **`beady-list.el`** — `beady-list-mode`: read-only project board. Loads issues asynchronously in parallel (`bd list`, `bd blocked`, `bd statuses`); all filtering, live search, sorting, grouping (including kanban board lanes), and hierarchical tree rendering happen locally in memory. Includes `beady-list-view-menu` (`v`) and `beady-list-dispatch` (`?`).
- **`beady-show.el`** — `beady-show-mode`: single-bead detail view with Markdown rendering, clickable relation buttons (parent/children/blockers/related), back/forward navigation history, and follow mode preview.
- **`beady-actions.el`** — Interactive mutations (status transitions, priority, claim/unclaim, labels, assignee, dependencies, field edits, creation) and `beady-compose-mode` buffers for multi-line Markdown comments/descriptions.
- **`beady-evil.el`** — Optional Evil keybindings following `evil-collection` conventions; auto-installed when `evil` is loaded and `beady-evil-integration` is non-nil.
- **`test/beady-test.el`** — ERT test suite: fast unit tests on synthetic fixtures (`beady-test-with-list`) plus integration tests against a temporary `bd` database.

## Code Conventions

- **Strictly use `bd --json`:** Never parse human-readable `bd` output for structured data. All reads go through `beady--run-json` or `beady--run-async` with `--json`; mutations go through `beady--mutate` (which handles `--force` confirmation prompts and refreshes all open project buffers via `beady-refresh-project`).
- **Emacs Lisp standards:**
  - Every file uses `lexical-binding: t`, `cl-lib`, `seq`, and `subr-x` (never deprecated `cl`).
  - Prefix public symbols with `beady-` (or `beady-list-`, `beady-show-`, `beady-compose-`) and private helpers/state with `--`.
  - Buffer-local state must use `defvar-local`.
  - Guard optional dependencies (`evil`, `markdown-mode`) with `declare-function` and `fboundp` / `featurep` so core files byte-compile cleanly without them.
- **UI & keybindings:** Keep Emacs and Evil bindings in sync, update transient menus (`beady-list-dispatch`, `beady-show-dispatch`) when adding commands, and preserve cached key-hint headers (`beady--hints`).

## Build, Test & Lint

With `make` available:

```bash
make compile   # Byte-compile with byte-compile-error-on-warn = t
make test      # Run ERT unit + integration tests
make lint      # Run checkdoc and package-lint
```

Direct `emacs -Q --batch` commands (when `make` is not in `PATH` or when testing single files):

```bash
# Byte-compile core files (warnings are errors)
emacs -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
  -f batch-byte-compile beady-core.el beady-actions.el beady-show.el beady-list.el beady.el

# Run all ERT tests (or replace `t` with a selector like `"beady-test-filter"`)
emacs -Q --batch -L . -L test -l test/beady-test.el \
  --eval '(ert-run-tests-batch-and-exit (quote (not (tag :integration))))'

# Run full ERT suite including bd CLI integration tests
emacs -Q --batch -L . -L test -l test/beady-test.el -f ert-run-tests-batch-and-exit

# Checkdoc lint
emacs -Q --batch -L . --eval '(dolist (f (quote ("beady-core.el" "beady-actions.el" "beady-show.el" "beady-list.el" "beady.el" "beady-evil.el"))) (checkdoc-file f))'
```

Pass extra package directories (for `evil`, `markdown-mode`, `package-lint`) with `LOAD_PATH="-L /path/to/pkg"` or extra `-L` flags.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:46cd31e7 -->
## Beads Issue Tracker (`bd`)

This project tracks its own issues with **Beads (`bd`)** in `.beads/`. Run `bd prime` for full workflow context.

```bash
bd ready                # List actionable work (open, unblocked)
bd list                 # List open issues
bd show <id>            # View issue details & dependencies
bd update <id> --claim  # Claim an issue atomically
bd close <id>           # Close completed work
bd memories             # List persistent project memories
bd remember "<insight>" # Store a durable project insight
```

- Use `bd` for project issue tracking (`beady-<hash>`).
- Do not commit, push, or run `bd sync` / `bd dolt push` unless asked by the user.
<!-- END BEADS INTEGRATION -->
