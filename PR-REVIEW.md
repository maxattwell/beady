# PR Review (Pre-flight)

Pre-publication review of the `beady` Emacs package as it stands in this
directory. There is no git repository here yet, so this reviews the working
tree directly rather than a branch diff.

## Summary

`beady` is in good shape. The code is clean, well documented, and unusually
well tested for a package of this size. Evidence gathered while reviewing:

- Byte-compiles cleanly with `byte-compile-error-on-warn t`, including the
  optional `beady-evil.el`, once `evil`/`markdown-mode` are on `LOAD_PATH`
  (`Cannot open load file: evil` otherwise — see blocker 4).
- Full ERT suite: `56/56` pass, `0` unexpected, once `evil`, `goto-chg` and
  `markdown-mode` are installed. Without them, `7` tests are silently skipped.
- `package-lint` (main file `beady.el`) reports exactly one warning:
  `beady-core.el:499:9: warning: with-eval-after-load is for use in
  configurations, and should rarely be used in packages.`
- `checkdoc` is clean on all six source files.
- Every `bd` flag the package invokes was checked against the real `bd 1.3.0`
  CLI and works (`--title`, `--status`, `--due`, `--until`, `--estimate`,
  `--external-ref`, `--set-labels`, `--add-label`, `--remove-label`,
  `--acceptance`, `--notes`, `--append-notes`, `dep add`, `comment id -- text`,
  `note id -- text`). The `bd blocked` / `bd show` JSON field names used by the
  code (`blocked_by`, `parent`, `dependencies`, `comment_count`) match reality.

The blockers below are publication hygiene and developer-experience issues,
not correctness bugs in the features themselves.

## Blockers (must fix before PR)

1. **No `LICENSE` file.** Every source file carries a GPL-3.0-or-later notice
   but the repository has no `LICENSE`/`COPYING` text. Add the GPLv3 text (and
   set the GitHub license) so the grant is unambiguous.
2. **Package metadata points at the wrong project.** `beady.el:9` sets
   `URL: https://github.com/gastownhall/beads` (the CLI, not beady), and
   `beady.el:5` is `Author: beady contributors` with no name or contact.
   `URL` is what `list-packages` / `describe-package` / MELPA surface; point it
   at the beady repository and give a real `Author`/`Maintainer` with an email.
3. **README claims transient is built into Emacs 29.1**, but it is a GNU ELPA
   package and is only shipped with much newer Emacs (this machine's Emacs 31
   bundles it). `Package-Requires` already lists `(transient "0.4.1")`, so it
   is installed automatically — fix the wording at `README.md:98` ("which is
   installed automatically") rather than implying it is bundled.
4. **`make compile` fails on a clean checkout without optional deps.**
   `Makefile:16,24` includes `beady-evil.el` in `SRCS`, and that file does
   `(require 'evil)`; with no `evil` on `LOAD_PATH`, compilation aborts with
   `Cannot open load file: evil`. The README's Development section tells
   contributors to run `make compile`. Either split optional sources into a
   separate target, make the default target tolerant, or document/automate
   installing `evil`, `goto-chg` and `markdown-mode` first.

## Should fix

1. **`beady-core.el:499` — the only `package-lint` warning.**
   `beady--maybe-setup-evil` uses `with-eval-after-load` inside the library.
   Prefer a normal hook or `(eval-after-load 'evil ...)`, or move the deferred
   setup into a configuration-friendly `defcustom`/function, so the lint target
   is warning-free.
2. **`beady-list--follow-timer` is global but used per buffer.**
   `beady-list.el:1293` declares it with `defvar` while `beady-list--follow`
   (1293–1308) cancels and replaces the single global timer. With two list
   buffers using follow mode, moving in one clobbers the pending preview of the
   other. Make it `defvar-local` and cancel it when follow mode is disabled.
3. **`make lint` is environment-dependent.** `Makefile:31` runs
   `package-lint-batch-and-exit` without refreshing archives; on a clean
   machine it reports `beady.el:7:38: error: Package transient is not
   installable.` until `package-refresh-contents` has run. Add a bootstrap step
   or document that the lint target needs the package archives (and transient)
   available.
4. **No CI.** There is no `.github/workflows` (or equivalent). Add a workflow
   that runs `make compile` and `make test` on Emacs 29/30/31, installing
   `transient`, `evil`, `goto-chg` and `markdown-mode` so the seven optional
   tests actually run instead of being skipped.
5. **`.gitignore` is minimal.** Only `*.elc` and `*-autoloads.el`. Add `*~`,
   `.#*`, `.DS_Store`, `.dir-locals.el` (if used) and any local `straight`/
   `elpaca` state so first-time contributors don't commit noise.
6. **Unverified performance claim in the README.** `README.md:355` says a
   "list of 2000 beads redraws in well under 100 ms." Measured here on a
   synthetic 2000-bead project: ~69 ms per full render (`beady-list--render`),
   ~4 ms for width/row prep. That is under 100 ms but not comfortably "well
   under"; either add a micro-benchmark to the test suite or soften the wording.
7. **`beady-evil-setup` mutates the global `transient-map`.**
   `beady-evil.el:175-176` binds `[escape]` in the shared `transient-map`,
   affecting every transient menu in the session. It is guarded, documented and
   opt-out, but consider scoping it to beady's own transient prefixes or
   calling it out more prominently.
8. **Repeated computation in compose header lines.** `beady-compose--header-line`
   (`beady-actions.el:472`) is installed as `(:eval ...)` and calls
   `beady--hints`, which walks `where-is-internal`, on every redisplay while
   typing. The list and show buffers cache hints (`beady-show--hint-cache`);
   do the same for compose buffers.
9. **`beady-list--descendants` (`beady-list.el:368`) rebuilds the frontier with
   `append` per node (O(n²)).** Fine for typical epics, but a very large
   subtree filter will be slow; a queue with `nconc`/two lists is linear.
10. **Packaging niceties.** No `CHANGELOG` and no `CONTRIBUTING`; GitHub will
    auto-generate neither. A changelog is expected for a versioned package
    (`beady-version` and the header both say 0.1.0).

## Tests to add (concrete test names + intent)

1. `beady-test-set-labels-empty-clears` — call `beady-set-labels` with `nil`
   and assert every existing label is removed (the interactive "replace with
   none" path currently only exercises add/remove).
2. `beady-test-defer-until` — `beady-defer` with a non-empty date, asserting
   `defer_until` is stored; the integration test only calls it with `""`.
3. `beady-test-edit-due-and-estimate` — round-trip `beady-edit-due` and
   `beady-edit-estimate` through `bd show --json`; both flags are currently
   untested end to end.
4. `beady-test-create-with-description` — assert the first compose line becomes
   the title and the remainder the description (the CLI supports it; the
   package path is untested).
5. `beady-test-column-profile-toggle` — `beady-list-toggle-column-profile`
   switches compact/wide and `beady-list-id-style 'hidden` drops the ID column.
6. `beady-test-follow-timer-buffer-local` — with two list buffers in follow
   mode, schedule a preview in one and assert the other's timer is untouched
   (guards the blocker-adjacent `beady-list--follow-timer` fix).
7. `beady-test-auto-refresh` — with `beady-list-auto-refresh-interval` set,
   a visible idle list refreshes and an invisible one / active transient does
   not.
8. `beady-test-wide-unicode-widths` — `beady--pad` and
   `beady-list--compute-widths` stay column-aligned for CJK/emoji titles and
   labels (the width code uses `string-width`/`truncate-string-to-width`, so a
   regression here would silently misalign the table).

## Notes on conventions/patterns (what to align to)

- The code already follows the right conventions: `lexical-binding`, `cl-lib`
  over `cl`, `declare-function` for optional deps, `defvar-local` for buffer
  state, `define-derived-mode`, generated autoload cookies, and a single
  `beady--run`/`beady--run-async` process seam. Keep that.
- Optional dependencies are handled correctly at runtime (guarded `require`,
  `declare-function`); the only packaging friction is that the *build* assumes
  them (blocker 4) and the *lint* target assumes archives are warm (should-fix 3).
- The literal autoload forms in `beady.el` (`beady-create-menu`,
  `beady-show-issue` pointing at feature `beady`) work because `beady` requires
  the defining libraries, but the conventional form is a `;;;###autoload`
  cookie directly above the `defun` in its own file. Consider moving them.
- `beady--run-async` cleanly cancels callbacks via a `beady-cancelled` process
  property and kills both buffers in the sentinel; the make-process failure
  path also cleaned up with no lingering processes in a probe. Good.
- Continue treating `bd` as the source of truth (`statuses`, `types`, custom
  statuses/categories) rather than hard-coding; the metadata cache and
  `beady--ordered-statuses` handle custom statuses sensibly.
