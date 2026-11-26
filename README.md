# xit.hx

A Helix-native Git UI written in Steel Scheme.

## Screenshot

<video src="https://github.com/user-attachments/assets/1ca7fbfa-fee8-4fec-94f3-4320f48499f0" controls width="800"></video>

## Install

Requires Helix with Steel scripting support, `git`, `bash`, `python3`, and a C
compiler (`cc`, or set `CC=gcc` / `CC=clang`).

```bash
git clone https://github.com/j03-dev/xit.hx.git
cd xit.hx
./install.sh
```

The installer copies `xit.scm` and its Git layer `xit-core.scm` into your Steel
cogs, installs `notify.hx`, the `xit` query, language registration, and builds
the grammar. You only require `xit.scm`; the core module is loaded from the same
directory automatically. It does not edit Helix source. Restart Helix after
installing.

## Helix config

This is the only config needed in `~/.config/helix/init.scm`:

```scheme
(require "xit/xit.scm")

(keymap (global)
  (normal
    (space
      (g ":Git")))))
```

`space g` opens the Git status buffer. If you do not want a shortcut, only keep
the `require` line and run `:Git` manually.

All other keys are native Helix or xit buffer keymaps installed automatically.
File paths containing spaces, Unicode characters, or glob-like characters are
handled literally, so no manual quoting is needed.

## Use

| Action | Key |
|---|---|
| Open Git status | `space g` or `:Git` |
| Stage file / section / selection | `s` |
| Unstage file / section / selection | `u` |
| Open commit editor | `c` |
| Commit | type message above the scissors separator, then `:w` (the staged diff below it is display-only) |
| Abort commit | `q` (Esc stays native and never aborts) |
| Discard changes / selection | `D` |
| View diff in `*git-diff*` | `:git-diff` (or `:Git diff`); selected files via `:git-diff-selection` |
| Fold / unfold a file's diff inline | `ret` or `tab` |
| Open file | `o` |
| Open branch manager | `b` or `:Git branches` |
| Open full branch graph | `g` in `*git-branches*` or `:Git graph` |
| Refresh status | `r` |
| Close xit buffer | `q` |
| Show all keys | `?` |

For selection staging, use normal Helix selection (`v`, `V`, `C-j`, multiple
cursors) over file lines, then press `s`, `u`, or `D` to stage, unstage, or
discard those files. To view a combined diff of a selection, use
`:git-diff-selection`. A folded file shows `>` before its name; press `ret` or
`tab` to unfold it into `v` and show its diff directly underneath. The `d` key
is intentionally unbound; diffs stay accessible via commands and inline folds.

More keys in `*git*`: `C` amend commit, `O` / `T` resolve conflicts, `S` / `U`
stage or unstage all, `P` / `p` push or pull. Closing with `q`, committing (or
aborting), and pulling reload all open Helix files from disk.

The `Head:` line shows the current branch, upstream, ahead/behind counts and
whether it needs a push or pull. The `Commit Graph` section shows every commit
in the repository with single-space separators between graph, hash, author and
subject. Every commit node is drawn as `o`, with explicit rails:

```text
o c05568a FITAHIANA Nomeniavo Joe Merge branch 'fix/selection-staging-diff'
|\
| o 615ec3b FITAHIANA Nomeniavo Joe feat: show staged diff
o | 7159a13 FITAHIANA Nomeniavo joe fix: selection staging diff (#1)
| o b33a0a4 FITAHIANA Nomeniavo Joe feat: collapse diff next files
|/
o 366547a FITAHIANA Nomeniavo Joe fix: remove esc from xit keybiding
```

The merge subject names the branch that was merged in, and the `← branch`
decoration on the node row identifies the branch it landed on. Tree-sitter
gives graph glyphs, hashes, authors and commit messages separate highlight
captures, so each uses a different color from the active Helix theme. A
non-breaking space separates author from message, so the visible gap stays at
exactly one space.

### Branch manager

`*git-branches*` lists every local branch with its upstream, ahead/behind
counts, status, last commit and subject.

| Action | Key |
|---|---|
| Check out branch | `ret` |
| Diff current branch against selected (`current...selected`) | `tab` |
| Create and switch to new branch from selected branch | `c` |
| Delete selected branch | `D` |
| Merge selected branch into current branch | `M` |
| Open full branch graph | `g` |
| Pull / push | `p` / `P` |
| Refresh / close / help | `r` / `q` / `?` |

Delete and discard require typed confirmation before they run. Deleting the
current branch is refused. The full graph in `*git-graph*` can be refreshed with
`r` and closed with `q`.

## Highlighting

Applied automatically:

- `*git*`, `*git-branches*`, `*git-graph*` → `xit` (hashes, authors, graph glyphs, branches, sections, status entries)
- `*git-commit*` → `git-commit`
- `*git-diff*` → `diff`

## Verify

```bash
hx --health xit
```

You should see `Tree-sitter parser: ✓` and `Highlight queries: ✓`.

## Update

```bash
cd xit.hx
git pull
./install.sh
```

Restart Helix after updating.

## If something is wrong

- `:Git` missing: check `(require "xit/xit.scm")` in `init.scm`.
- No highlighting: run `./install.sh` and restart Helix.
- `#false` in the status line: your cog is old; run `./install.sh`.
