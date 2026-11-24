#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/helix"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
COG_DIR="$DATA_DIR/steel/cogs/xit"
LANGS_FILE="$CONFIG_DIR/languages.toml"
RUNTIME_DIR="$CONFIG_DIR/runtime"
QUERY_DIR="$RUNTIME_DIR/queries/xit"

mkdir -p "$CONFIG_DIR" "$QUERY_DIR" "$RUNTIME_DIR/grammars" "$COG_DIR"

# Install the Steel plugin.
cp "$SCRIPT_DIR/xit.scm" "$COG_DIR/xit.scm"
cp "$SCRIPT_DIR/xit-core.scm" "$COG_DIR/xit-core.scm"
cp "$SCRIPT_DIR/cog.scm" "$COG_DIR/cog.scm"
cp "$SCRIPT_DIR/README.md" "$COG_DIR/README.md"

# Keep grammar/assets with the cog so the language config can point at them.
rm -rf "$COG_DIR/grammar" "$COG_DIR/languages" "$COG_DIR/runtime"
cp -R "$SCRIPT_DIR/grammar" "$COG_DIR/grammar"
cp -R "$SCRIPT_DIR/languages" "$COG_DIR/languages"
cp -R "$SCRIPT_DIR/runtime" "$COG_DIR/runtime"

# Install the query where Helix will find it.
cp "$SCRIPT_DIR/runtime/queries/xit/highlights.scm" "$QUERY_DIR/highlights.scm"

# Register the xit language with an absolute path to the installed grammar.
tmp_lang="$(mktemp)"
python3 - "$SCRIPT_DIR/languages/xit.toml" "$COG_DIR/grammar/xit" > "$tmp_lang" <<'PY'
import sys

source, grammar_path = sys.argv[1], sys.argv[2]
with open(source) as handle:
    content = handle.read()
print(content.replace("@XIT_GRAMMAR_PATH@", grammar_path), end="")
PY

if ! grep -q '^name = "xit"$' "$LANGS_FILE" 2>/dev/null; then
  printf '\n# >>> xit.hx >>>\n' >> "$LANGS_FILE"
  cat "$tmp_lang" >> "$LANGS_FILE"
  printf '# <<< xit.hx <<<\n' >> "$LANGS_FILE"
  echo "Registered xit language in $LANGS_FILE"
else
  echo "xit language already registered in $LANGS_FILE"
fi
rm -f "$tmp_lang"

# Build only the xit grammar. Calling `hx --grammar build` rebuilds every
# configured grammar and is noisy when source trees for other grammars are not
# installed.
case "$(uname -s)" in
  Darwin) ext="dylib" ;;
  MINGW*|MSYS*|CYGWIN*) ext="dll" ;;
  *) ext="so" ;;
esac

grammar_src="$COG_DIR/grammar/xit/src"
grammar_lib="$RUNTIME_DIR/grammars/xit.$ext"
cc_bin="${CC:-cc}"

if command -v "$cc_bin" >/dev/null 2>&1; then
  echo "Building xit grammar..."
  extra_flags=()
  if [ "$ext" = "so" ]; then
    extra_flags=(-Wl,-z,relro,-z,now)
  fi
  "$cc_bin" -fPIC -shared -fno-exceptions -I "$grammar_src" \
    -o "$grammar_lib" -xc -std=c11 "$grammar_src/parser.c" "${extra_flags[@]}"
else
  echo "$cc_bin not found; install a C compiler to build the xit grammar." >&2
fi

echo "xit.hx installed. Restart Helix."
