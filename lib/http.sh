# shellcheck shell=bash
# Small API transport shared by the PR utilities. Sourcing performs no I/O.
# http_request returns text; http_json also validates JSON. Pass curl arguments.
http_request() {
  local response body status auth_header_value header_value auth_header_index
  local auth_header_seen=false
  local -a curl_args

  curl_args=()
  auth_header_value=""
  auth_header_index=-1
  while [ $# -gt 0 ]; do
    case "$1" in
      -H|--header)
        if [ $# -lt 2 ]; then
          echo "❌ API request is missing a header value." >&2
          return 1
        fi
        header_value="$2"
        case "$header_value" in
          [Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:*)
            case "$header_value" in
              *$'\r'*|*$'\n'*)
                echo "❌ API request contains an invalid authentication header." >&2
                return 1
                ;;
            esac
            if [ "$auth_header_seen" = true ]; then
              echo "❌ API request contains multiple authentication headers." >&2
              return 1
            fi
            auth_header_seen=true
            auth_header_value="$header_value"
            auth_header_index=${#curl_args[@]}
            curl_args+=("-H" "")
            ;;
          *) curl_args+=("$1" "$header_value") ;;
        esac
        shift 2
        ;;
      --header=*)
        header_value="${1#--header=}"
        case "$header_value" in
          [Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:*)
            case "$header_value" in
              *$'\r'*|*$'\n'*)
                echo "❌ API request contains an invalid authentication header." >&2
                return 1
                ;;
            esac
            if [ "$auth_header_seen" = true ]; then
              echo "❌ API request contains multiple authentication headers." >&2
              return 1
            fi
            auth_header_seen=true
            auth_header_value="$header_value"
            auth_header_index=${#curl_args[@]}
            curl_args+=("-H" "")
            ;;
          *) curl_args+=("$1") ;;
        esac
        shift
        ;;
      *) curl_args+=("$1"); shift ;;
    esac
  done

  # Do not retry mutations automatically, or print response bodies/credentials on error.
  if ! response="$(
    if [ "$auth_header_seen" = true ]; then
      # A private pipe keeps headers off disk, including on interruption. This
      # descriptor belongs to this subshell; caller stdin, fds, and traps stay intact.
      exec 3< <(printf '%s\n' "$auth_header_value") || exit 1
      curl_args[$((auth_header_index + 1))]="@/dev/fd/3"
    fi
    curl -sS --connect-timeout 10 --max-time 60 \
      -w '\n%{http_code}' "${curl_args[@]}" 2>/dev/null
  )"; then
    echo "❌ API request failed: connection error or timeout." >&2
    return 1
  fi

  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    case "$status" in
      401|403) echo "❌ API request denied (HTTP $status): check authentication and permissions." >&2 ;;
      *) echo "❌ API request failed (HTTP $status)." >&2 ;;
    esac
    return 1
  fi
  printf '%s\n' "$body"
}

http_json() {
  local body
  body="$(http_request "$@")" || return 1
  if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    echo "❌ API request returned invalid or empty JSON." >&2
    return 1
  fi
  printf '%s\n' "$body"
}
