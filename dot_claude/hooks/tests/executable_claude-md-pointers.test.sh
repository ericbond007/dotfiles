#!/usr/bin/env bash
# claude-md-pointers.test.sh — every pointer in CLAUDE.md of the shape
#   → origin: `~/.claude/<path>` § "<heading>"   or   → mechanics: `~/.claude/<path>` § "<heading>"
# must name a file that exists under $ROOT (default ~/.claude) AND a line in it that is
# EXACTLY a Markdown heading with that text (fenced code blocks are skipped). "→ wiki:" pointers are counted, not checked.
# MANUAL: nothing runs this automatically — run it before committing a CLAUDE.md change
# and on each peer after a sync. Usage: [CLAUDE_MD=<file>] [ROOT=<dir>] $0
set -u
md="${CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
root="${ROOT:-$HOME/.claude}"
fail=0; n=0
while IFS= read -r ptr; do
    n=$((n+1))
    kind=$(printf '%s' "$ptr" | sed -E 's/^→ (mechanics|origin): `([^`]+)` § "([^"]+)"$/\1/')
    file=$(printf '%s' "$ptr" | sed -E 's/^→ (mechanics|origin): `([^`]+)` § "([^"]+)"$/\2/')
    head=$(printf '%s' "$ptr" | sed -E 's/^→ (mechanics|origin): `([^`]+)` § "([^"]+)"$/\3/')
    case "$file" in
        "~/.claude/"*) path="$root/${file#\~/.claude/}";;
        "~/"*)         path="$HOME/${file#\~/}";;
        /*)            path="$file";;
        *)             path="$root/$file";;
    esac
    if [[ ! -f "$path" ]]; then echo "FAIL  $kind: missing file $path   ($ptr)"; fail=1; continue; fi
    if ! awk '/^(```|~~~)/{f=!f; next} !f' "$path" | grep -E '^ {0,3}#{1,6}[[:blank:]]' | sed -E 's/^ {0,3}#{1,6}[[:blank:]]+//; s/[[:blank:]]+#+[[:blank:]]*$//; s/[[:blank:]]+$//' | grep -qxF -- "$head"; then
        echo "FAIL  $kind: no heading exactly '$head' in $path"; fail=1; continue
    fi
    echo "ok    $kind: $file § \"$head\""
done < <(grep -oE '→ (mechanics|origin): `[^`]+` § "[^"]+"' -- "$md")
loose=$(grep -oE '→ (mechanics|origin):' -- "$md" | wc -l); [[ "$loose" -ne "$n" ]] && { echo "FAIL  $((loose - n)) pointer(s) do not match the exact shape → kind: \`file\` § \"Heading\""; fail=1; }
echo "info  $(grep -oE '→ wiki: `' -- "$md" | wc -l) '→ wiki:' pointer(s) not checked (wanda-only)"
(( n == 0 )) && { echo "FAIL  no pointers found in $md"; fail=1; }
(( fail == 0 )) && echo "PASS  $n pointer(s) resolve exactly" || echo "FAIL  see above"
exit $fail
