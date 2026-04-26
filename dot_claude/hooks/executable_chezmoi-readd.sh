#!/usr/bin/env bash
# PostToolUse hook for Edit|Write|MultiEdit.
#
# Mirror Claude-driven changes into the chezmoi source tree:
#   - File is already managed     → `chezmoi re-add` (capture modification)
#   - File is new but its parent
#     directory is managed        → `chezmoi add`    (start tracking it)
#   - Otherwise                   → no-op
#
# Silent on success. Always exits 0.
set -u

payload=$(cat)
file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
[ -z "$file_path" ] && exit 0

# Single managed-list query, used for both file and parent-dir lookups.
managed=$(chezmoi managed --path-style=absolute 2>/dev/null) || exit 0

# Skip templated sources — re-add can't overwrite a .tmpl, and chezmoi
# resolves an existing source path even before the target exists.
src_path=$(chezmoi source-path -- "$file_path" 2>/dev/null || true)
case "$src_path" in
    *.tmpl) exit 0 ;;
esac

if grep -qxF "$file_path" <<<"$managed"; then
    chezmoi re-add -- "$file_path" || true
elif grep -qxF "$(dirname -- "$file_path")" <<<"$managed"; then
    chezmoi add -- "$file_path" || true
fi

exit 0
