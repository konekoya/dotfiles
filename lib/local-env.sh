# shellcheck shell=bash
# On-demand loader for the per-machine settings in alias/.env.
# Source this file from a script; sourcing never reads alias/.env itself.
#
# alias/.env is not sourced by the interactive shell, so tokens are not inherited by every
# child process. Scripts that need a value call local_env_load for exactly those names.
#
# The file is portable between Bash and Zsh because agent skills source it into whichever
# shell the tool runs; keep arrays and expansions to what both shells accept.

# Remember where alias/.env lives, relative to this file, at source time.
if [ -n "${ZSH_VERSION:-}" ]; then
  eval '_local_env_source="${(%):-%x}"'
else
  _local_env_source="${BASH_SOURCE[0]}"
fi
_LOCAL_ENV_FILE="$(cd "$(dirname "$_local_env_source")/.." && pwd)/alias/.env"
unset _local_env_source

# local_env_load NAME...
#
# Sets each NAME that is unset or empty in the caller's environment from alias/.env. A
# non-empty value the caller already provided always wins and is left untouched.
#
# A value taken from the file becomes a plain shell variable that is never exported, even if
# the caller had exported an empty variable of that name, so programs started afterwards
# (git, az, curl) do not inherit it. Nothing is printed.
#
# A missing file or a name that .env does not define is not an error; an invalid name returns
# 1. The file is evaluated in a subshell, so nothing else it assigns leaks into the caller.
local_env_load() {
  local name value assignments
  local -a missing

  missing=()
  for name in "$@"; do
    case "$name" in
      '' | [0-9]* | *[!A-Za-z0-9_]*) return 1 ;;
    esac
    eval "value=\${$name:-}"
    [ -n "$value" ] || missing+=("$name")
  done

  [ "${#missing[@]}" -gt 0 ] || return 0
  [ -f "$_LOCAL_ENV_FILE" ] || return 0

  assignments="$(
    for name in "${missing[@]}"; do unset "$name"; done
    # shellcheck source=/dev/null # alias/.env is per-machine and not tracked
    source "$_LOCAL_ENV_FILE" >/dev/null 2>&1 || true
    for name in "${missing[@]}"; do
      eval "value=\${$name:-}"
      if [ -n "$value" ]; then printf '%s=%q\n' "$name" "$value"; fi
    done
  )" || assignments=""

  [ -n "$assignments" ] || return 0

  # Unsetting first drops an inherited export attribute, so the new value stays unexported.
  for name in "${missing[@]}"; do unset "$name"; done
  eval "$assignments"
  return 0
}
