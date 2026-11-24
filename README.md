# xit.hx

An interactive Git status, buffer management, and conflict resolution plugin for Helix, written in Steel Scheme.

---

## Install

```bash
./install.sh
```

Requires `bash`, `python3`, and a C compiler (`cc` by default, or set `CC`).

The installer:

- copies the Steel plugin to `$XDG_DATA_HOME/steel/cogs/xit`
  (default `~/.local/share/steel/cogs/xit`),
- installs the `xit` query into `$XDG_CONFIG_HOME/helix/runtime/queries/xit`,
- registers the `xit` language in `$XDG_CONFIG_HOME/helix/languages.toml`,
- compiles only `xit.so` into `$XDG_CONFIG_HOME/helix/runtime/grammars`.

It does not modify the Helix source tree. Restart Helix after installing.

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
        (D ":git-diff")
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
D = ":git-diff"
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
  `.git/XIT_COMMIT_EDITMSG`. Write the message, then press **`:w`** to save and
  create the commit. Helix stays open; only the commit buffer
  closes. `q` / `esc` aborts.
- **`:Git diff`** (or `D` in `*git*`): Opens diff in a buffer.
- **`:Git push`** / **`:Git pull`**: Push or pull changes.

---

## Keybindings in `*git*` Buffer

| Key | Command | Description |
|---|---|---|
| `s` | `:git-stage` | Stage file / section (or mark conflict resolved) |
| `u` | `:git-unstage` | Unstage file / section |
| `d` | `:git-discard` | Discard modifications / delete untracked file (asks `y` to confirm) |
| `ret` | `:git-open` | Open file in Helix |
| `D` | `:git-diff` | View diff in buffer |
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

`w`, `x`, `g`, and `-` are intentionally unbound in `*git*`, so Helix’s native
word motion, selection, go-to, and other motions keep working there. `d` asks for
confirmation: type `y` or `yes` and press Enter, or press Esc to cancel.

Selection support: use Helix selection commands (`v`/`V`, `C-j`, multiple cursors)
in `*git*` to cover several file lines, then press `s` to stage all selected files
or `u` to unstage them (undo staging). Section headers are only acted on when the
cursor alone is on them, so a multi-line selection cannot stage/unstage a whole
section by accident. The same operations are available as `:git-stage-selection`
and `:git-unstage-selection`.

Languages are applied automatically: `*git*` (status) uses the custom `xit`
grammar, `*git-commit*` uses `git-commit`, and `*git-diff*` uses `diff`. The
`xit` grammar highlights commit hashes, commit subjects, section headers, and
staged/unstaged/untracked entries without running `:lang` manually. If the
`xit` language is not installed, `*git*` falls back to `git-commit` highlighting.
