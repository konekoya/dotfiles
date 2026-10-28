# shellcheck shell=bash
# Helpers for the optional private work-notes repository, shared by install.sh and doctor.
#
# The repository itself owns its layout: links.tsv at its root lists what to link into this
# machine. Each non-comment line has three whitespace-separated fields:
#
#   home           <source>  <target>        link $HOME/<target> to <source>
#   claude-memory  <source>  <project-path>  link Claude Code's memory directory for the project
#                                            at $HOME/<project-path> to <source>
#
# <source> is relative to the work-notes root; <target> and <project-path> are relative to
# $HOME. Absolute paths and ".." components are rejected so a manifest cannot reach outside.

work_notes_dir() {
  printf '%s' "${WORK_NOTES_DIR:-$HOME/work-notes}"
}

work_notes_relative_path_is_safe() {
  local path="$1"
  case "$path" in
    '' | /* | .. | ../* | */.. | */../*) return 1 ;;
  esac
  return 0
}

# Claude Code keys project data by the absolute project path with every character other
# than letters and digits replaced by "-".
work_notes_claude_memory_dir() {
  local project_path="$1"
  printf '%s/.claude/projects/%s/memory' "$HOME" "$(printf '%s' "$project_path" | sed 's/[^A-Za-z0-9]/-/g')"
}

# work_notes_manifest_lines FILE LABEL [SKIP_SOURCES]
#
# Parses one manifest. Prints "ok<TAB>source<TAB>target<TAB>kind<TAB>LABEL" with absolute paths,
# or "invalid<TAB>LABEL line N<TAB>reason". Entries whose source is listed (one per line) in
# SKIP_SOURCES are left out.
work_notes_manifest_lines() {
  local manifest="$1"
  local label="$2"
  local skip_sources="${3:-}"
  local dir
  local line_number=0
  local line kind source target extra

  [ -f "$manifest" ] || return 0
  dir="$(dirname "$manifest")"

  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line" in
      '' | '#'*) continue ;;
    esac
    read -r kind source target extra <<< "$line"
    case "$kind" in
      '' | '#'*) continue ;;
    esac
    if [ -z "$target" ] || [ -n "$extra" ]; then
      printf 'invalid\t%s line %s\t%s\n' "$label" "$line_number" "expected three fields: kind, source, target"
      continue
    fi
    if ! work_notes_relative_path_is_safe "$source" || ! work_notes_relative_path_is_safe "$target"; then
      printf 'invalid\t%s line %s\t%s\n' "$label" "$line_number" "paths must be relative and must not contain .."
      continue
    fi
    if [ -n "$skip_sources" ] && printf '%s\n' "$skip_sources" | grep -Fxq -- "$source"; then
      continue
    fi
    case "$kind" in
      home) printf 'ok\t%s\t%s\t%s\t%s\n' "$dir/$source" "$HOME/$target" "$kind" "$label" ;;
      claude-memory) printf 'ok\t%s\t%s\t%s\t%s\n' "$dir/$source" "$(work_notes_claude_memory_dir "$HOME/$target")" "$kind" "$label" ;;
      *) printf 'invalid\t%s line %s\t%s\n' "$label" "$line_number" "unknown kind '$kind' (use home or claude-memory)" ;;
    esac
  done < "$manifest"
}

# work_notes_entries DIR
#
# Prints the entries of DIR/links.tsv and the machine-local DIR/links.local.tsv in the format
# of work_notes_manifest_lines. A local entry replaces every shared entry with the same source,
# so one machine can keep a project at a different path without changing the shared manifest.
work_notes_entries() {
  local dir="$1"
  local local_manifest="$dir/links.local.tsv"
  local local_sources=""

  if [ -f "$local_manifest" ]; then
    local_sources="$(awk '!/^[[:space:]]*(#|$)/ && NF == 3 { print $2 }' "$local_manifest")"
    work_notes_manifest_lines "$local_manifest" links.local.tsv
  fi
  work_notes_manifest_lines "$dir/links.tsv" links.tsv "$local_sources"
}
