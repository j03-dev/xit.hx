#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/helix"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
COG_DIR="$DATA_DIR/steel/cogs/xit"
NOTIFY_DIR="$DATA_DIR/steel/cogs/notify"
LANGS_FILE="$CONFIG_DIR/languages.toml"
RUNTIME_DIR="$CONFIG_DIR/runtime"
QUERY_DIR="$RUNTIME_DIR/queries/xit"
GRAMMAR_SRC="$COG_DIR/grammar/xit/src"

fail() {
  echo "error: $*" >&2
  exit 1
}

for dep in git python3; do
  command -v "$dep" >/dev/null 2>&1 || fail "$dep is required"
done

case "$(uname -s)" in
  Darwin) ext="dylib" ;;
  MINGW*|MSYS*|CYGWIN*) ext="dll" ;;
  *) ext="so" ;;
esac

cc_bin="${CC:-cc}"
command -v "$cc_bin" >/dev/null 2>&1 || fail "C compiler not found (set CC=gcc or CC=clang if '$cc_bin' is unavailable)"

mkdir -p "$CONFIG_DIR" "$QUERY_DIR" "$RUNTIME_DIR/grammars" "$(dirname "$COG_DIR")"

# xit.scm requires notify/notify.scm at load time.
if [ -f "$NOTIFY_DIR/notify.scm" ]; then
  echo "notify.hx dependency already installed."
else
  echo "Installing notify.hx dependency into $NOTIFY_DIR..."
  rm -rf "$NOTIFY_DIR"
  git clone --depth 1 https://github.com/chuwy/notify.hx.git "$NOTIFY_DIR"
fi

# Install the Steel plugin and its grammar/runtime assets.
mkdir -p "$COG_DIR"
cp "$SCRIPT_DIR/xit.scm" "$COG_DIR/xit.scm"
cp "$SCRIPT_DIR/xit-core.scm" "$COG_DIR/xit-core.scm"
cp "$SCRIPT_DIR/cog.scm" "$COG_DIR/cog.scm"
cp "$SCRIPT_DIR/README.md" "$COG_DIR/README.md"

rm -rf "$COG_DIR/grammar" "$COG_DIR/languages" "$COG_DIR/runtime"
cp -R "$SCRIPT_DIR/grammar" "$COG_DIR/grammar"
cp -R "$SCRIPT_DIR/languages" "$COG_DIR/languages"
cp -R "$SCRIPT_DIR/runtime" "$COG_DIR/runtime"

cp "$SCRIPT_DIR/runtime/queries/xit/highlights.scm" "$QUERY_DIR/highlights.scm"

# Build the language block with an absolute path to the installed grammar source.
tmp_lang="$(mktemp)"
trap 'rm -f "$tmp_lang"' EXIT
python3 - "$SCRIPT_DIR/languages/xit.toml" "$COG_DIR/grammar/xit" > "$tmp_lang" <<'PY'
import sys

source, grammar_path = sys.argv[1], sys.argv[2]
with open(source) as handle:
    content = handle.read()
print(content.replace("@XIT_GRAMMAR_PATH@", grammar_path), end="")
PY

# Replace the managed block on updates, or append it on first install.
python3 - "$LANGS_FILE" "$tmp_lang" <<'PY'
from pathlib import Path
import sys

langs_path = Path(sys.argv[1])
block_path = Path(sys.argv[2])
start, end = "# >>> xit.hx >>>", "# <<< xit.hx <<<"
block = block_path.read_text().rstrip("\n")
text = langs_path.read_text() if langs_path.exists() else ""

if start in text and end in text:
    before, rest = text.split(start, 1)
    _, after = rest.split(end, 1)
    text = before.rstrip() + "\n\n" + start + "\n" + block + "\n" + end + "\n" + after.lstrip("\n")
    action = "Updated"
elif '\nname = "xit"' in "\n" + text:
    print(
        f"warning: existing xit language found in {langs_path}; leaving it unchanged",
        file=sys.stderr,
    )
    langs_path.write_text(text)
    raise SystemExit(0)
else:
    text = text.rstrip() + "\n\n" + start + "\n" + block + "\n" + end + "\n"
    action = "Registered"

langs_path.write_text(text)
print(f"{action} xit language in {langs_path}")
PY

# Build only the xit grammar. `hx --grammar build` rebuilds every configured
# grammar and is noisy when other grammars' source trees are not installed.
echo "Building xit grammar..."
extra_flags=()
if [ "$ext" = "so" ]; then
  extra_flags=(-Wl,-z,relro,-z,now)
fi

"$cc_bin" -fPIC -shared -fno-exceptions -I "$GRAMMAR_SRC" \
  -o "$RUNTIME_DIR/grammars/xit.$ext" -xc -std=c11 \
  "$GRAMMAR_SRC/parser.c" "${extra_flags[@]}"

echo "xit.hx installed. Restart Helix."
