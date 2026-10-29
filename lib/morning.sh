# shellcheck shell=bash
# Helpers for the `morning` start-of-day command, shared by scripts/morning, install.sh and doctor.
#
# MORNING_REPOS in alias/.env lists the repositories to sync, separated by colons or newlines.
# A leading "~" expands to $HOME. Order is kept, trailing slashes and duplicates are dropped.

morning_repo_paths() {
  local entry

  printf '%s\n' "${MORNING_REPOS:-}" | tr ':' '\n' | while IFS= read -r entry; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -n "$entry" ] || continue
    # shellcheck disable=SC2088 # '~/' is matched literally, then expanded to $HOME
    case "$entry" in
      '~') entry="$HOME" ;;
      '~/'*) entry="$HOME/${entry#'~/'}" ;;
    esac
    [ "$entry" = / ] || entry="${entry%/}"
    printf '%s\n' "$entry"
  done | awk '!seen[$0]++'
}

# morning_repo_problem PATH: prints why PATH cannot be synced, or nothing when it can.
morning_repo_problem() {
  local path="$1"

  if [ ! -e "$path" ]; then
    printf 'does not exist'
  elif ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'is not a Git repository'
  elif ! git -C "$path" remote 2>/dev/null | grep -Fxq origin; then
    printf "has no 'origin' remote"
  fi
}
