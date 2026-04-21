#!/usr/bin/env bash
# PostToolUse hook for Edit|Write|MultiEdit.
# If the edit touched a chezmoi-managed target in $HOME (and the source is
# not a template), run `chezmoi re-add` to mirror the change back to the
# source tree so it gets captured in the next sync commit.
#
# Silent on success. Always exits 0.
set -u

payload=$(cat)
file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
[ -z "$file_path" ] && exit 0

# Only care about managed targets. Edits under the chezmoi source tree don't
# need re-adding — they're already "the source."
chezmoi managed --path-style=absolute 2>/dev/null | grep -qxF "$file_path" || exit 0

# Skip templated files — re-add won't overwrite a .tmpl.
src_path=$(chezmoi source-path -- "$file_path" 2>/dev/null || true)
case "$src_path" in
    *.tmpl) exit 0 ;;
esac

chezmoi re-add --quiet -- "$file_path" 2>/dev/null || true
exit 0
