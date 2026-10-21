# shellcheck shell=bash
# shellcheck disable=SC2034 # This sourced library communicates result fields through its public ADO_* variables.
# Shared Azure DevOps repository and authentication helpers.
# Source this file from a script; sourcing never prints diagnostics or performs API calls.
#
# ado_resolve_remote_context sets ADO_REMOTE_* and provider-specific repository values.
# ado_resolve_repo_context additionally requires Azure DevOps and sets ADO_PROFILE.
# ado_get_auth_header selects a repository-bound PAT or validated Azure CLI profile.

ado_same_value() {
  local left right
  left="$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')"
  right="$(printf '%s' "${2-}" | tr '[:upper:]' '[:lower:]')"
  [ "$left" = "$right" ]
}

ado_valid_path_segment() {
  local segment="$1" remainder lowered

  [ -n "$segment" ] || return 1
  case "$segment" in
    .|..|*/*|*\\*|*\?*|*\#*|*" "*|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;;
  esac

  remainder="$(printf '%s' "$segment" | sed -E 's/%[[:xdigit:]]{2}//g')" || return 1
  case "$remainder" in *%*) return 1 ;; esac
  lowered="$(printf '%s' "$segment" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in *%2f*|*%5c*) return 1 ;; esac
  return 0
}

ado_parse_remote() {
  local remote_url="${1-}" org project repo

  ADO_ORG=""
  ADO_PROJECT=""
  ADO_REPO=""
  ADO_ORG_PATH=""
  ADO_PROJECT_PATH=""
  ADO_REPO_PATH=""
  ADO_REMOTE_URL=""

  case "$remote_url" in
    *" "*|*$'\t'*|*$'\r'*|*$'\n'*|*\?*|*\#*) return 1 ;;
  esac

  if [[ "$remote_url" =~ ^git@ssh\.dev\.azure\.com:v3/([^/]+)/([^/]+)/([^/]+)$ ]]; then
    org="${BASH_REMATCH[1]}"
    project="${BASH_REMATCH[2]}"
    repo="${BASH_REMATCH[3]}"
  elif [[ "$remote_url" =~ ^ssh://([^/@]+@)?ssh\.dev\.azure\.com/v3/([^/]+)/([^/]+)/([^/]+)$ ]]; then
    org="${BASH_REMATCH[2]}"
    project="${BASH_REMATCH[3]}"
    repo="${BASH_REMATCH[4]}"
  elif [[ "$remote_url" =~ ^https://([^/@]+@)?dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/]+)$ ]]; then
    org="${BASH_REMATCH[2]}"
    project="${BASH_REMATCH[3]}"
    repo="${BASH_REMATCH[4]}"
  elif [[ "$remote_url" =~ ^https://([^/@]+@)?([^.\/:]+)\.visualstudio\.com/([^/]+)/_git/([^/]+)$ ]]; then
    org="${BASH_REMATCH[2]}"
    project="${BASH_REMATCH[3]}"
    repo="${BASH_REMATCH[4]}"
  else
    return 1
  fi

  repo="${repo%.git}"
  if ! ado_valid_path_segment "$org" || ! ado_valid_path_segment "$project" || ! ado_valid_path_segment "$repo"; then
    return 1
  fi

  ADO_ORG="$org"
  ADO_PROJECT="$project"
  ADO_REPO="$repo"
  ADO_ORG_PATH="$org"
  ADO_PROJECT_PATH="$project"
  ADO_REPO_PATH="$repo"
  ADO_REMOTE_URL="$remote_url"
  return 0
}

ado_parse_github_remote() {
  local remote_url="${1-}" owner repo

  GITHUB_OWNER=""
  GITHUB_REPO=""
  ADO_REMOTE_URL=""
  case "$remote_url" in
    *" "*|*$'\t'*|*$'\r'*|*$'\n'*|*\?*|*\#*) return 1 ;;
  esac

  if [[ "$remote_url" =~ ^git@github\.com:([^/]+)/([^/]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
  elif [[ "$remote_url" =~ ^ssh://([^/@]+@)?github\.com/([^/]+)/([^/]+)$ ]]; then
    owner="${BASH_REMATCH[2]}"
    repo="${BASH_REMATCH[3]}"
  elif [[ "$remote_url" =~ ^https://([^/@]+@)?github\.com/([^/]+)/([^/]+)$ ]]; then
    owner="${BASH_REMATCH[2]}"
    repo="${BASH_REMATCH[3]}"
  else
    return 1
  fi

  repo="${repo%.git}"
  if ! ado_valid_path_segment "$owner" || ! ado_valid_path_segment "$repo"; then
    return 1
  fi

  GITHUB_OWNER="$owner"
  GITHUB_REPO="$repo"
  ADO_REMOTE_URL="$remote_url"
  return 0
}

ado_local_config_value() {
  local key="$1" values
  values="$(git config --local --get-all "$key" 2>/dev/null || true)"
  case "$values" in
    *$'\n'*) return 2 ;;
    '') return 1 ;;
  esac
  printf '%s' "$values"
}

ado_resolve_remote_context() {
  local remote_name fetch_urls push_urls fetch_url push_url fetch_provider
  local fetch_org fetch_project fetch_repo fetch_owner fetch_github_repo
  local push_provider push_org push_project push_repo push_owner push_github_repo config_status

  ADO_REMOTE_ERROR=""
  ADO_REMOTE_NAME=""
  ADO_REMOTE_URL=""
  ADO_REMOTE_PROVIDER=""
  ADO_ORG=""
  ADO_PROJECT=""
  ADO_REPO=""
  ADO_ORG_PATH=""
  ADO_PROJECT_PATH=""
  ADO_REPO_PATH=""
  GITHUB_OWNER=""
  GITHUB_REPO=""

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ADO_REMOTE_ERROR="Not inside a Git repository."
    return 1
  fi

  if remote_name="$(ado_local_config_value azure-devops.remote 2>/dev/null)"; then
    :
  else
    config_status=$?
    if [ "$config_status" -eq 2 ]; then
      ADO_REMOTE_ERROR="More than one Azure DevOps remote is configured. Keep one 'azure-devops.remote' value in this repository."
      return 1
    fi
    remote_name=""
  fi
  [ -n "$remote_name" ] || remote_name=origin
  if [[ ! "$remote_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    ADO_REMOTE_ERROR="The configured Azure DevOps remote name is invalid. Set it with 'git config --local azure-devops.remote <name>'."
    return 1
  fi

  if ! fetch_urls="$(git remote get-url --all "$remote_name" 2>/dev/null)" || [ -z "$fetch_urls" ]; then
    ADO_REMOTE_ERROR="Selected Git remote is missing. Set 'azure-devops.remote' to an existing remote or add 'origin'."
    return 1
  fi
  case "$fetch_urls" in
    *$'\n'*)
      ADO_REMOTE_ERROR="Selected Git remote has multiple fetch URLs. Use a remote with one fetch URL."
      return 1
      ;;
  esac
  fetch_url="$fetch_urls"

  if ! push_urls="$(git remote get-url --push --all "$remote_name" 2>/dev/null)" || [ -z "$push_urls" ]; then
    ADO_REMOTE_ERROR="Selected Git remote has no push URL. Configure one that targets the same repository."
    return 1
  fi
  case "$push_urls" in
    *$'\n'*)
      ADO_REMOTE_ERROR="Selected Git remote has multiple push URLs. Use a remote with one push URL."
      return 1
      ;;
  esac
  push_url="$push_urls"

  if ado_parse_remote "$fetch_url"; then
    fetch_provider=azure
    fetch_org="$ADO_ORG"
    fetch_project="$ADO_PROJECT"
    fetch_repo="$ADO_REPO"
    fetch_owner=""
    fetch_github_repo=""
  elif ado_parse_github_remote "$fetch_url"; then
    fetch_provider=github
    fetch_org=""
    fetch_project=""
    fetch_repo=""
    fetch_owner="$GITHUB_OWNER"
    fetch_github_repo="$GITHUB_REPO"
  else
    ADO_REMOTE_ERROR="Selected Git remote uses an unsupported host or URL format. Use a canonical Azure DevOps or GitHub SSH/HTTPS URL."
    return 1
  fi

  if ado_parse_remote "$push_url"; then
    push_provider=azure
    push_org="$ADO_ORG"
    push_project="$ADO_PROJECT"
    push_repo="$ADO_REPO"
    push_owner=""
    push_github_repo=""
  elif ado_parse_github_remote "$push_url"; then
    push_provider=github
    push_org=""
    push_project=""
    push_repo=""
    push_owner="$GITHUB_OWNER"
    push_github_repo="$GITHUB_REPO"
  else
    ADO_REMOTE_ERROR="Selected Git remote has an unsupported push URL. Configure matching Azure DevOps or GitHub fetch and push destinations."
    return 1
  fi

  if [ "$fetch_provider" != "$push_provider" ]; then
    ADO_REMOTE_ERROR="Selected Git remote has conflicting fetch and push destinations. Configure matching repositories or select another remote."
    return 1
  fi
  if [ "$fetch_provider" = azure ]; then
    if ! ado_same_value "$fetch_org" "$push_org" || ! ado_same_value "$fetch_project" "$push_project" || ! ado_same_value "$fetch_repo" "$push_repo"; then
      ADO_REMOTE_ERROR="Selected Git remote has conflicting fetch and push destinations. Configure matching repositories or select another remote."
      return 1
    fi
  elif ! ado_same_value "$fetch_owner" "$push_owner" || ! ado_same_value "$fetch_github_repo" "$push_github_repo"; then
    ADO_REMOTE_ERROR="Selected Git remote has conflicting fetch and push destinations. Configure matching repositories or select another remote."
    return 1
  fi

  ADO_REMOTE_NAME="$remote_name"
  ADO_REMOTE_PROVIDER="$fetch_provider"
  if [ "$fetch_provider" = azure ]; then
    ado_parse_remote "$fetch_url" || return 1
  else
    ado_parse_github_remote "$fetch_url" || return 1
  fi
  return 0
}

ado_profile_value() {
  local profile="$1" key="$2" values
  values="$(git config --get-all "azure-devops.${profile}.${key}" 2>/dev/null || true)"
  case "$values" in
    *$'\n'*) return 2 ;;
    '') return 1 ;;
  esac
  printf '%s' "$values"
}

ado_bind_profile() {
  local profile="$1" expected_org="$2" organization auth tenant user object_id config_status

  ADO_PROFILE=""
  ADO_PROFILE_ORG=""
  ADO_PROFILE_AUTH=""
  ADO_PROFILE_TENANT=""
  ADO_PROFILE_USER=""
  ADO_PROFILE_OBJECT_ID=""
  ADO_PROFILE_ERROR=""

  # Underscores would collide with hyphens when deriving the PAT variable name.
  if [[ ! "$profile" =~ ^[a-z][a-z0-9-]*$ ]]; then
    ADO_PROFILE_ERROR="Profile names must start with a lowercase letter and contain only lowercase letters, digits, or hyphens. Underscores are not allowed."
    return 1
  fi
  organization="$(ado_profile_value "$profile" organization)" || {
    ADO_PROFILE_ERROR="Profile '$profile' has no single organization configured in Git config."
    return 1
  }
  if ! ado_valid_path_segment "$organization" || ! ado_same_value "$organization" "$expected_org"; then
    ADO_PROFILE_ERROR="Profile '$profile' is configured for a different organization than the selected repository."
    return 1
  fi
  if auth="$(ado_profile_value "$profile" auth 2>/dev/null)"; then
    :
  else
    config_status=$?
    if [ "$config_status" -eq 2 ]; then
      ADO_PROFILE_ERROR="Profile '$profile' has more than one auth mode configured."
      return 1
    fi
    auth=pat
  fi
  case "$auth" in
    pat|azure-cli) ;;
    *)
      ADO_PROFILE_ERROR="Profile '$profile' has an unsupported auth mode. Use 'pat' or 'azure-cli'."
      return 1
      ;;
  esac

  tenant=""
  user=""
  object_id=""
  if [ "$auth" = azure-cli ]; then
    tenant="$(ado_profile_value "$profile" tenant)" || {
      ADO_PROFILE_ERROR="Azure CLI profile '$profile' requires one tenant ID."
      return 1
    }
    user="$(ado_profile_value "$profile" user)" || {
      ADO_PROFILE_ERROR="Azure CLI profile '$profile' requires one expected Azure CLI user name."
      return 1
    }
    object_id="$(ado_profile_value "$profile" object-id)" || {
      ADO_PROFILE_ERROR="Azure CLI profile '$profile' requires one expected user object ID."
      return 1
    }
    if [[ ! "$tenant" =~ ^[A-Fa-f0-9-]{36}$ ]] || [[ ! "$object_id" =~ ^[A-Fa-f0-9-]{36}$ ]] || [[ ! "$user" =~ ^[^[:space:][:cntrl:]]+$ ]]; then
      ADO_PROFILE_ERROR="Azure CLI profile '$profile' has an invalid tenant ID, user object ID, or user name."
      return 1
    fi
  fi

  ADO_PROFILE="$profile"
  ADO_PROFILE_ORG="$organization"
  ADO_PROFILE_AUTH="$auth"
  ADO_PROFILE_TENANT="$tenant"
  ADO_PROFILE_USER="$user"
  ADO_PROFILE_OBJECT_ID="$object_id"
  ADO_PROFILE_ERROR=""
  return 0
}

ado_resolve_repo_context() {
  local profile explicit_org config_status

  ADO_CONTEXT_ERROR=""
  ADO_PROFILE=""
  ADO_PROFILE_ORG=""
  ADO_PROFILE_AUTH=""
  ADO_PROFILE_TENANT=""
  ADO_PROFILE_USER=""
  ADO_PROFILE_OBJECT_ID=""
  ADO_PROFILE_ERROR=""

  if ! ado_resolve_remote_context; then
    ADO_CONTEXT_ERROR="$ADO_REMOTE_ERROR"
    return 1
  fi
  if [ "$ADO_REMOTE_PROVIDER" != azure ]; then
    ADO_CONTEXT_ERROR="Selected Git remote is not a recognized Azure DevOps remote."
    return 1
  fi

  explicit_org="${AZURE_DEVOPS_ORG:-}"
  if [ -n "$explicit_org" ] && ! ado_same_value "$explicit_org" "$ADO_ORG"; then
    ADO_CONTEXT_ERROR="AZURE_DEVOPS_ORG does not match the selected repository organization. Remove the override or configure a matching per-repository profile."
    return 1
  fi

  if profile="$(ado_local_config_value azure-devops.profile 2>/dev/null)"; then
    :
  else
    config_status=$?
    if [ "$config_status" -eq 2 ]; then
      ADO_CONTEXT_ERROR="More than one Azure DevOps profile is selected. Keep one 'azure-devops.profile' value in this repository."
      return 1
    fi
    profile=""
  fi
  if [ -n "$profile" ]; then
    if ! ado_bind_profile "$profile" "$ADO_ORG"; then
      ADO_CONTEXT_ERROR="$ADO_PROFILE_ERROR"
      return 1
    fi
  fi
  return 0
}

ado_decode_jwt_claims() {
  local token="$1" encoded decoded padding

  ADO_TOKEN_TENANT=""
  ADO_TOKEN_OBJECT_ID=""
  case "$token" in
    *.*.*) ;;
    *) return 1 ;;
  esac
  encoded="${token#*.}"
  encoded="${encoded%%.*}"
  [ -n "$encoded" ] || return 1
  encoded="$(printf '%s' "$encoded" | tr '_-' '/+')"
  case $((${#encoded} % 4)) in
    1) return 1 ;;
    2) padding='==' ;;
    3) padding='=' ;;
    *) padding='' ;;
  esac
  if ! decoded="$(printf '%s' "${encoded}${padding}" | base64 -D 2>/dev/null)"; then
    decoded="$(printf '%s' "${encoded}${padding}" | base64 -d 2>/dev/null)" || return 1
  fi
  ADO_TOKEN_TENANT="$(printf '%s' "$decoded" | jq -r '.tid // empty' 2>/dev/null)"
  ADO_TOKEN_OBJECT_ID="$(printf '%s' "$decoded" | jq -r '.oid // empty' 2>/dev/null)"
  [ -n "$ADO_TOKEN_TENANT" ] && [ -n "$ADO_TOKEN_OBJECT_ID" ]
}

ado_profile_pat_name() {
  local profile="$1" upper
  upper="$(printf '%s' "$profile" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
  printf 'AZURE_DEVOPS_PAT_%s' "$upper"
}

ado_get_auth_header() {
  local token resource_id pat_name account_json account_user account_tenant expected_org

  ADO_AUTH_HEADER=""
  ADO_AUTH_ERROR=""
  [ -n "${ADO_ORG:-}" ] || {
    ADO_AUTH_ERROR="Resolve an Azure DevOps organization before requesting authentication."
    return 1
  }

  if [ -n "${ADO_PROFILE:-}" ]; then
    if [ -z "${ADO_PROFILE_ORG:-}" ] || ! ado_same_value "$ADO_PROFILE_ORG" "$ADO_ORG"; then
      ADO_AUTH_ERROR="Selected Azure DevOps profile does not match the resolved repository organization. No request was sent."
      return 1
    fi
    if [ "$ADO_PROFILE_AUTH" = pat ]; then
      pat_name="$(ado_profile_pat_name "$ADO_PROFILE")"
      if declare -F local_env_load >/dev/null 2>&1; then local_env_load "$pat_name"; fi
      eval "token=\${$pat_name:-}"
      if [ -z "$token" ]; then
        ADO_AUTH_ERROR="Set ${pat_name} in alias/.env or in the environment for the selected Azure DevOps profile."
        return 1
      fi
      ADO_AUTH_HEADER="Authorization: Basic $(printf ':%s' "$token" | base64 2>/dev/null | tr -d '\r\n')"
      if [ "$ADO_AUTH_HEADER" = "Authorization: Basic " ]; then
        ADO_AUTH_ERROR="Could not encode the selected Azure DevOps profile PAT."
        return 1
      fi
      return 0
    fi

    if ! command -v az >/dev/null 2>&1; then
      ADO_AUTH_ERROR="Azure CLI profile '$ADO_PROFILE' requires Azure CLI. Install it and sign in as the configured account."
      return 1
    fi
    if ! command -v jq >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
      ADO_AUTH_ERROR="Azure CLI profile validation requires jq and base64."
      return 1
    fi
    if ! account_json="$(az account show --query '{user:user.name,tenantId:tenantId}' -o json 2>/dev/null)" || [ -z "$account_json" ]; then
      ADO_AUTH_ERROR="Azure CLI profile '$ADO_PROFILE' could not verify the active account. Sign in to the configured account without switching CLI defaults from this command."
      return 1
    fi
    account_user="$(printf '%s' "$account_json" | jq -r '.user // empty' 2>/dev/null)"
    account_tenant="$(printf '%s' "$account_json" | jq -r '.tenantId // empty' 2>/dev/null)"
    if ! ado_same_value "$account_user" "$ADO_PROFILE_USER" || ! ado_same_value "$account_tenant" "$ADO_PROFILE_TENANT"; then
      ADO_AUTH_ERROR="The active Azure CLI account does not match Azure DevOps profile '$ADO_PROFILE'. No request was sent."
      return 1
    fi

    resource_id="499b84ac-1321-427f-aa17-267ca6975798"
    if ! token="$(az account get-access-token --resource "$resource_id" --tenant "$ADO_PROFILE_TENANT" --query accessToken -o tsv 2>/dev/null)" || [ -z "$token" ]; then
      ADO_AUTH_ERROR="Azure CLI profile '$ADO_PROFILE' could not obtain an Azure DevOps access token. No request was sent."
      return 1
    fi
    case "$token" in
      *" "*|*$'\t'*|*$'\r'*|*$'\n'*)
        ADO_AUTH_ERROR="Azure CLI profile '$ADO_PROFILE' returned an invalid access token. No request was sent."
        return 1
        ;;
    esac
    if ! ado_decode_jwt_claims "$token" || ! ado_same_value "$ADO_TOKEN_TENANT" "$ADO_PROFILE_TENANT" || ! ado_same_value "$ADO_TOKEN_OBJECT_ID" "$ADO_PROFILE_OBJECT_ID"; then
      ADO_AUTH_ERROR="Azure CLI profile '$ADO_PROFILE' token claims do not match its configured tenant and user object ID. No request was sent."
      return 1
    fi
    ADO_AUTH_HEADER="Authorization: Bearer $token"
    return 0
  fi

  if declare -F local_env_load >/dev/null 2>&1; then local_env_load AZURE_DEVOPS_ORG AZURE_DEVOPS_PAT; fi
  expected_org="${AZURE_DEVOPS_ORG:-}"
  if [ -z "$expected_org" ]; then
    ADO_AUTH_ERROR="No Azure DevOps authentication profile is selected. Configure a per-repository profile, or set both AZURE_DEVOPS_ORG and AZURE_DEVOPS_PAT for one organization."
    return 1
  fi
  if ! ado_same_value "$expected_org" "$ADO_ORG"; then
    ADO_AUTH_ERROR="AZURE_DEVOPS_ORG does not match the selected repository organization. Remove the override or configure a matching per-repository profile."
    return 1
  fi
  if [ -z "${AZURE_DEVOPS_PAT:-}" ]; then
    ADO_AUTH_ERROR="Legacy Azure CLI fallback is disabled because its identity cannot be safely bound to an organization. Configure an Azure CLI profile with organization, tenant, user, and object ID, or use a per-organization PAT profile."
    return 1
  fi

  token="$AZURE_DEVOPS_PAT"
  ADO_AUTH_HEADER="Authorization: Basic $(printf ':%s' "$token" | base64 2>/dev/null | tr -d '\r\n')"
  if [ "$ADO_AUTH_HEADER" = "Authorization: Basic " ]; then
    ADO_AUTH_ERROR="Could not encode AZURE_DEVOPS_PAT for Azure DevOps authentication."
    return 1
  fi
  return 0
}
