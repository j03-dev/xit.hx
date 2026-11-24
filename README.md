# xit.hx

A Helix-native Git UI written in Steel Scheme. It gives you an interactive
`*git*` status buffer, buffer-local Helix keybindings, file-backed commit editing
with native `:w`, selection staging/unstaging, and custom syntax highlighting.

---

## Features

- Interactive Git status in `*git*`: staged, unstaged, untracked, and conflicts.
- Stage/unstage the file under the cursor, a section header, or a Helix selection.
- Commit editor at `.git/XIT_COMMIT_EDITMSG`; write the message with native `:w`.
- Diffs open in a normal `*git-diff*` buffer with `diff` highlighting.
- Automatic languages: `*git*` uses a custom `xit` tree-sitter grammar,
  `*git-commit*` uses `git-commit`, and `*git-diff*` uses `diff`.
- `d` discards with a confirmation prompt; `x` stays free for Helix selection.

---

## Requirements

- Helix built with **Steel** scripting support and `init.scm` enabled
  (tested with Helix 25.07.1 + Steel).
- `git`
- `bash`
- `python3`
- A C compiler: `cc` by default, or set `CC=gcc` / `CC=clang`.
- Internet access on first install if `notify.hx` is not already installed.

No Helix source changes are needed. The installer writes only to your Helix
config/data directories and your Steel cogs directory.

---

## Quick install

```bash
git clone https://github.com/j03-dev/xit.hx.git
cd xit.hx
./install.sh
```

Then load xit from your Helix `init.scm` (usually
`~/.config/helix/init.scm`):

```scheme
(require "xit/xit.scm")
```

Restart Helix.

The installer:

- installs `notify.hx` into `$XDG_DATA_HOME/steel/cogs/notify` if missing,
- copies xit into `$XDG_DATA_HOME/steel/cogs/xit`
  (default `~/.local/share/steel/cogs/xit`),
- installs the `xit` query into `$XDG_CONFIG_HOME/helix/runtime/queries/xit`,
- registers/updates the `xit` language block in
  `$XDG_CONFIG_HOME/helix/languages.toml`,
- compiles only `xit.so` into `$XDG_CONFIG_HOME/helix/runtime/grammars`.

You can remove the cloned source after installing; the cog contains everything
it needs.

---

## Optional global shortcuts

Add these to `init.scm` if you want quick access from any buffer:

```scheme
(keymap (global)
  (normal
    (space
      (g
        (g ":Git")
        (c ":Git commit")
        (d ":git-diff")
        (D ":git-diff")
        (s ":git-stage")
        (u ":git-unstage")
        (r ":git-refresh")))))
```

Or add this to `~/.config/helix/config.toml`:

```toml
[keys.normal.space.g]
g = ":Git"
c = ":Git commit"
d = ":git-diff"
D = ":git-diff"
s = ":git-stage"
u = ":git-unstage"
p = ":git-push"
f = ":git-pull"
r = ":git-refresh"
```

xit already installs buffer-local keymaps for `*git*`, `*git-commit*`, and
`*git-diff*`; the shortcuts above are only for convenience.

---

## Verify the installation

```bash
hx --health xit
```

You should see:

```text
Tree-sitter parser: ✓
Highlight queries: ✓
```

Then open Helix and run `:Git`. Check the language with `:lang`; the status
buffer should report `xit`. If it reports `git-commit`, the `xit` language was
not found and the fallback is active.

---

## Basic usage

1. Open the status buffer with `:Git` (or `<space>gg` if configured).
2. Move to a file line and press `s` to stage or `u` to unstage.
3. Use Helix selections (`v`, `V`, `C-j`, multiple cursors) across several file
   lines, then press `s` or `u` to apply the action to all of them.
4. Press `c` to open the commit editor.
5. Type the commit message, then press native `:w` to save and commit.

Helix stays open; only the commit buffer closes and `*git*` refreshes. `q` or
`esc` aborts the commit.

---

## Keybindings in `*git*`

| Key | Command | Description |
|---|---|---|
| `s` | `:git-stage` | Stage file / section, or every file in the selection |
| `u` | `:git-unstage` | Unstage file / section, or every file in the selection |
| `d` | `:git-discard` | Discard changes / delete untracked file; asks `y` to confirm |
| `ret` | `:git-open` | Open file in Helix |
| `D` | `:git-diff` | View diff in a buffer |
| `O` | `:git-resolve-ours` | Resolve conflict with OURS version and stage |
| `T` | `:git-resolve-theirs` | Resolve conflict with THEIRS version and stage |
| `c` | `:git-commit` | Open commit buffer |
| `C` | `:git-commit-amend` | Amend last commit |
| `S` | `:git-stage-all` | Stage all changes (`git add -A`) |
| `U` | `:git-unstage-all` | Unstage all staged changes |
| `P` | `:git-push` | Push to remote |
| `p` | `:git-pull` | Pull from remote |
| `r` | `:git-refresh` | Refresh status |
| `q` | `:git-close` | Close buffer |
| `?` | `:git-help` | Toggle help cheat sheet |

In the commit editor:

| Key | Command | Description |
|---|---|---|
| `:w` | Helix write | Writes `.git/XIT_COMMIT_EDITMSG`; the save hook commits |
| `q` / `esc` | `:git-commit-abort` | Abort and close |

`w`, `x`, `g`, and `-` are intentionally unbound in `*git*`, so native Helix
word motion, selection, and go-to keys keep working. `d` asks for confirmation:
type `y` or `yes` and press Enter, or press Esc to cancel.

Section headers are acted on only when the cursor alone is on them; a multi-line
selection cannot stage or unstage a whole section by accident. The same
operations are available as `:git-stage-selection` and
`:git-unstage-selection`.

---

## Syntax highlighting

Languages are applied automatically:

| Buffer | Language | Highlights |
|---|---|---|
| `*git*` | `xit` | hashes, subjects, section headers, staged/unstaged/untracked entries |
| `*git-commit*` | `git-commit` | subject, comments, branch, paths, change kinds |
| `*git-diff*` | `diff` | additions and deletions |

If the `xit` language is missing, `*git*` falls back to `git-commit`
highlighting. Re-run `./install.sh` and restart Helix to restore it.

---

## Update

```bash
cd xit.hx
git pull
./install.sh
```

Restart Helix after updating. The installer refreshes the cog, query, grammar,
and the managed `xit` block in `languages.toml`.

---

## Troubleshooting

- **`:Git` is not a command**: add `(require "xit/xit.scm")` to `init.scm` and
  restart Helix.
- **No `xit` highlighting**: run `hx --health xit`, re-run `./install.sh`, and
  restart Helix.
- **`#false` appears in the status line**: your cog copy is outdated; re-run
  `./install.sh` and restart Helix.
- **`D` opens diff, `d` discards**: this is intentional. `d` always asks for
  confirmation first.
