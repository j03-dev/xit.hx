# xit.hx

An interactive Git status, buffer management, and conflict resolution plugin for Helix, written in Steel Scheme.

---

## Setup in `init.scm`

Load xit and add optional global shortcuts in your `~/.config/helix/init.scm`:

```scheme
(require "xit/xit.scm")

(keymap (global)
  (normal
    (space
      (g
        (g ":Git")
        (c ":Git commit")
        (d ":git-diff")
        (D ":git-diff-split")
        (s ":git-stage")
        (u ":git-unstage")
        (r ":git-refresh")))))
```

No extra keymap setup is needed. xit installs the `*git*`, `*git-commit*`, and
`*git-diff*` buffer-local keymaps automatically, inheriting your current global
keymaps.

---

## Global Shortcuts in `config.toml` (Optional)

Add to `~/.config/helix/config.toml` to control Git from any file buffer:

```toml
[keys.normal.space.g]
g = ":Git"
c = ":Git commit"
d = ":git-diff"
D = ":git-diff-split"
s = ":git-stage"
u = ":git-unstage"
p = ":git-push"
f = ":git-pull"
r = ":git-refresh"
```

---

## How to Use It

- **`:Git`** (or `<space>gg`): Opens the interactive Git status buffer (`*git*`).
- **`:Git commit`** (or `<space>gc`): Opens the commit editor backed by
  `.git/XIT_COMMIT_EDITMSG`. Write the message, then press **`:w`** (or plain
  `w`) to save and create the commit. Helix stays open; only the commit buffer
  closes. `q` / `esc` aborts.
- **`:Git diff`**: Opens diff in a buffer.
- **`:Git diff-split`** (or `D`): Opens diff in a **vertical split**.
- **`:Git push`** / **`:Git pull`**: Push or pull changes.

---

## Keybindings in `*git*` Buffer

| Key | Command | Description |
|---|---|---|
| `s` | `:git-stage` | Stage file / section (or mark conflict resolved) |
| `u` | `:git-unstage` | Unstage file / section |
| `-` | `:git-toggle-stage` | Toggle staged state |
| `d` | `:git-discard` | Discard modifications / delete untracked file |
| `ret` | `:git-open` | Open file in Helix |
| `g` | `:git-diff` | View diff in buffer |
| `D` | `:git-diff-split` | View diff in vertical split |
| `O` | `:git-resolve-ours` | Resolve conflict with OURS version and stage |
| `T` | `:git-resolve-theirs` | Resolve conflict with THEIRS version and stage |
| `c` | `:git-commit` | Open commit buffer |
| `C` | `:git-commit-amend` | Amend last commit |
| `S` | `:git-stage-all` | Stage all changes (`git add -A`) |
| `U` | `:git-unstage-all` | Unstage all staged changes |
| `P` | `:git-push` | Push to remote |
| `p` | `:git-pull` | Pull from remote |
| `r` | `:git-refresh` | Refresh status |
| `w` | `:git-save` | Apply buffer edits |
| `q` | `:git-close` | Close buffer |
| `?` | `:git-help` | Toggle help cheat sheet |

In the commit editor:

| Key | Command | Description |
|---|---|---|
| `w` | `:git-commit-finish` | Save and commit |
| `:w` | Helix write | Writes `.git/XIT_COMMIT_EDITMSG`; the save hook commits |
| `q` / `esc` | `:git-commit-abort` | Abort and close |

`x` is intentionally unbound in `*git*`, so Helix’s native selection commands
(such as `x` to select a character) keep working there.

Selection support: use Helix selection commands (`v`/`V`, `C-j`, multiple cursors)
in `*git*` to cover several file lines, then press `s` to stage all selected files
or `u` to unstage them (undo staging). Section headers are only acted on when the
cursor alone is on them, so a multi-line selection cannot stage/unstage a whole
section by accident. The same operations are available as `:git-stage-selection`
and `:git-unstage-selection`.

Languages are applied automatically: `*git*` (status) and `*git-commit*` use
`git-commit`, while the `*git-diff*` / split diff buffers use `git-diff`
(falling back to `diff` when `git-diff` is not configured). This highlights
comments, headers, additions and deletions without running `:lang` manually.
