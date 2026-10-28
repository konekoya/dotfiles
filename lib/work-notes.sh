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

# work_notes_entries DIR
#
# Prints one tab-separated line per manifest entry: "ok<TAB>source<TAB>target<TAB>kind" with
# absolute paths, or "invalid<TAB>line number<TAB>reason". Prints nothing without links.tsv.
work_notes_entries() {
  local dir="$1"
  local manifest="$dir/links.tsv"
  local line_number=0
  local line kind source target extra

  [ -f "$manifest" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line" in
      '' | '#'*) continue ;;
    esac
    read -r kind source target extra <<< "$line"
    case "$kind" in
      '#'*) continue ;;
    esac
    if [ -z "$target" ] || [ -n "$extra" ]; then
      printf 'invalid\t%s\t%s\n' "$line_number" "expected three fields: kind, source, target"
      continue
    fi
    if ! work_notes_relative_path_is_safe "$source" || ! work_notes_relative_path_is_safe "$target"; then
      printf 'invalid\t%s\t%s\n' "$line_number" "paths must be relative and must not contain .."
      continue
    fi
    case "$kind" in
      home) printf 'ok\t%s\t%s\t%s\n' "$dir/$source" "$HOME/$target" "$kind" ;;
      claude-memory) printf 'ok\t%s\t%s\t%s\n' "$dir/$source" "$(work_notes_claude_memory_dir "$HOME/$target")" "$kind" ;;
      *) printf 'invalid\t%s\t%s\n' "$line_number" "unknown kind '$kind' (use home or claude-memory)" ;;
    esac
  done < "$manifest"
}
