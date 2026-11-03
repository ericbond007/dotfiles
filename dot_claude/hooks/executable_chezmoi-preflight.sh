#!/usr/bin/env bash
# PreToolUse hook for Edit|Write (MultiEdit dropped 2026-11-03 — the tool no longer exists).
# Warns (non-blocking) if the target file is chezmoi-related AND:
#  - the chezmoi source is behind origin (risk of conflicts on next sync), or
#  - the target file is generated from a template (user should edit the .tmpl
#    in the source instead of the rendered target).
#
# Emits warnings on stderr; always exits 0 so edits are never blocked.
set -u

payload=$(cat)
file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
[ -z "$file_path" ] && exit 0

src=$(chezmoi source-path 2>/dev/null) || exit 0
[ -z "$src" ] && exit 0

# Is this file chezmoi-related? Either under the source tree or a managed target.
under_source=0
is_managed=0
case "$file_path" in
    "$src"/*) under_source=1 ;;
esac
if [ "$under_source" -eq 0 ]; then
    if chezmoi managed --path-style=absolute 2>/dev/null | grep -qxF "$file_path"; then
        is_managed=1
    fi
fi

[ "$under_source" -eq 0 ] && [ "$is_managed" -eq 0 ] && exit 0

# Warn if source is behind origin. Cache fetch for 5 minutes.
cache="$src/.git/FETCH_HEAD"
now=$(date +%s)
last=0
[ -f "$cache" ] && last=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
if [ $((now - last)) -gt 300 ]; then
    git -C "$src" fetch --quiet origin 2>/dev/null || true
fi

behind=$(git -C "$src" rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
if [ "$behind" != "0" ] && [ -n "$behind" ]; then
    printf 'chezmoi source is %s commit(s) behind origin. Consider: (cd %s && git pull --rebase && chezmoi apply) before editing.\n' \
        "$behind" "$src" >&2
fi

# If editing a managed target that has a template, nudge toward the .tmpl.
if [ "$is_managed" -eq 1 ]; then
    src_rel=$(chezmoi source-path -- "$file_path" 2>/dev/null || true)
    case "$src_rel" in
        *.tmpl)
            printf 'Note: %s is rendered from a template. Edit %s instead to avoid losing changes on the next chezmoi apply.\n' \
                "$file_path" "$src_rel" >&2
            ;;
    esac
fi

exit 0
