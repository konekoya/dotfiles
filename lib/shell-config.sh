# shellcheck shell=bash
# Print a path as it should appear in ~/.zshrc: "~/..." (style "tilde") or "$HOME/..." (style
# "home") when it is under $HOME, otherwise the absolute path.
shell_config_ref() {
  local path="$1" style="$2"
  case "$path" in
    "$HOME"/*)
      if [ "$style" = home ]; then
        printf '$HOME/%s' "${path#"$HOME"/}"
      else
        # shellcheck disable=SC2088 # literal "~/" is the intended output
        printf '~/%s' "${path#"$HOME"/}"
      fi
      ;;
    *) printf '%s' "$path" ;;
  esac
}

# Recognize standalone dotfiles settings without executing the user's shell config.
# Comments and commands that merely mention a dotfiles path are ignored. The dotfiles
# directory is wherever this file lives, so the repository can be cloned anywhere.
shell_config_has_setting() {
  local file="$1" setting="$2" dotfiles_dir
  [ -f "$file" ] || return 1
  dotfiles_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
  awk -v setting="$setting" -v dir="$dotfiles_dir" '
    function unquote(value, first, last) {
      first = substr(value, 1, 1)
      last = substr(value, length(value), 1)
      if ((first == "\"" || first == "\047") && first == last)
        return substr(value, 2, length(value) - 2)
      return value
    }
    BEGIN {
      home = ENVIRON["HOME"]
      rel = (index(dir, home "/") == 1) ? substr(dir, length(home) + 1) : ""
    }
    function matches_path(value, suffix, quote) {
      return value == dir suffix ||
        (rel != "" && quote != "\047" && (value == "$HOME" rel suffix || value == "${HOME}" rel suffix)) ||
        (rel != "" && quote != "\047" && quote != "\"" && value == "~" rel suffix)
    }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+#.*/, "", line)
      sub(/[ \t;]+$/, "", line)
      if (setting == "aliases" && line ~ /^(source|\.)[ \t]+/) {
        sub(/^(source|\.)[ \t]+/, "", line)
        if (matches_path(unquote(line), "/alias/.alias", substr(line, 1, 1))) found = 1
      }
      if (setting == "shared" && line ~ /^(source|\.)[ \t]+/) {
        sub(/^(source|\.)[ \t]+/, "", line)
        if (matches_path(unquote(line), "/zsh/.zshrc.shared", substr(line, 1, 1))) found = 1
      }
      if (setting == "path" && line ~ /^(export[ \t]+)?PATH=/) {
        sub(/^(export[ \t]+)?PATH=/, "", line)
        count = split(unquote(line), entries, ":")
        for (i = 1; i <= count; i++)
          if (matches_path(entries[i], "/scripts", substr(line, 1, 1))) found = 1
      }
    }
    END { exit !found }
  ' "$file"
}
