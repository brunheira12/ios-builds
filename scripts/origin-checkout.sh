#!/usr/bin/env bash
# Check out one pinned Origin commit for ios-build.
#
# Origin stays the source of truth. This script mints a short-lived installation
# access token (repository:contents:read only) from an Origin App JWT, then
# clones with Git HTTPS. The token is never placed in a remote URL, argv, the
# git config, or the public log (fd 3).
#
# A repo tarball (GET /v1/origin/repos/{owner}/{repo}/tarball/{ref}) is not used:
# the archive has no gitlinks, so a Snes9x submodule pin cannot be fetched or
# checked. Git HTTPS is the documented contents:read path and keeps submodule
# SHAs. CloneKit is an Enterprise option and is not used here.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

origin_fail() {
  printf '%s\n' "$1" >&3
  exit 1
}

origin_openssl() {
  if [ -n "${OPENSSL_BIN:-}" ] && [ -x "${OPENSSL_BIN}" ]; then
    printf '%s\n' "$OPENSSL_BIN"
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    prefix=$(brew --prefix openssl@3 2>/dev/null || true)
    if [ -n "$prefix" ] && [ -x "$prefix/bin/openssl" ]; then
      printf '%s\n' "$prefix/bin/openssl"
      return
    fi
  fi
  command -v openssl
}

origin_b64url() {
  "$OSSL" base64 -A | tr '+/' '-_' | tr -d '='
}

origin_validate_repo() {
  case "$1" in
    *.git|*/*/*|*/|/*|*..*|.|.*) return 1 ;;
  esac
  case "$1" in
    [A-Za-z0-9._-]*/[A-Za-z0-9._-]*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  return 0
}

origin_validate_ref() {
  case "$1" in
    *[!0-9A-Fa-f]*) return 1 ;;
  esac
  n=${#1}
  [ "$n" -ge 7 ] && [ "$n" -le 40 ]
}

origin_validate_branch() {
  [ -n "$1" ] || return 1
  case "$1" in
    -*|/*|*/|refs/*|*..*|.|..) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  return 0
}

origin_validate_relpath() {
  [ -n "$1" ] || return 1
  case "$1" in
    /*|*\\*|..|../*|*/..|*/../*|*..*) return 1 ;;
  esac
  return 0
}

origin_token_body() {
  if [ -n "${1:-}" ]; then
    printf '{"scopes":["repository:contents:read"],"repositoryIds":["%s"]}\n' "$1"
  else
    printf '%s\n' '{"scopes":["repository:contents:read"]}'
  fi
}

origin_rewrite_submodule_url() {
  url=$1
  case "$url" in
    git@github.com:*)
      printf 'https://github.com/%s\n' "${url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      printf 'https://github.com/%s\n' "${url#ssh://git@github.com/}"
      ;;
    git@origin.cursor.com:*)
      printf 'https://origin.cursor.com/%s\n' "${url#git@origin.cursor.com:}"
      ;;
    ssh://git@origin.cursor.com/*)
      printf 'https://origin.cursor.com/%s\n' "${url#ssh://git@origin.cursor.com/}"
      ;;
    *)
      printf '%s\n' "$url"
      ;;
  esac
}

# Read SHAs on stdin. Print the single SHA whose lowercase form starts with the
# lowercase ref. Exit 2 when none match, 3 when more than one matches.
origin_select_commit() {
  ref_low=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  hits=$2
  : > "$hits"
  while IFS= read -r sha || [ -n "$sha" ]; do
    [ -n "$sha" ] || continue
    sha_low=$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')
    case "$sha_low" in
      "$ref_low"*) printf '%s\n' "$sha" >> "$hits" ;;
    esac
  done
  count=$(wc -l < "$hits" | tr -d ' ')
  if [ "$count" -eq 0 ]; then
    return 2
  fi
  if [ "$count" -ne 1 ]; then
    return 3
  fi
  cat "$hits"
}

origin_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

origin_checkout_main() {
  if ! { true >&3; } 2>/dev/null; then
    exec 3>&1
  fi

  : "${RUNNER_TEMP:?}"
  : "${GITHUB_ENV:?}"
  case "$RUNNER_TEMP" in
    ""|"/") origin_fail "runner temp missing" ;;
  esac

  command -v git >/dev/null 2>&1 || origin_fail "git not available"
  command -v curl >/dev/null 2>&1 || origin_fail "curl not available"
  command -v jq >/dev/null 2>&1 || origin_fail "jq not available"
  OSSL=$(origin_openssl) || origin_fail "openssl ed25519 signer not available"
  [ -n "$OSSL" ] && [ -x "$OSSL" ] || origin_fail "openssl ed25519 signer not available"

  [ -n "${ORIGIN_APP_ID:-}" ] && [ -n "${ORIGIN_INSTALLATION_ID:-}" ] && [ -n "${ORIGIN_APP_PRIVATE_KEY:-}" ] || origin_fail "origin auth not configured"
  case "$ORIGIN_APP_PRIVATE_KEY" in
    *"BEGIN PRIVATE KEY"*) ;;
    *) origin_fail "origin key not configured" ;;
  esac
  case "$ORIGIN_APP_ID" in
    app_[A-Za-z0-9]*) ;;
    *) origin_fail "origin app id not configured" ;;
  esac
  case "$ORIGIN_APP_ID" in
    *[!A-Za-z0-9_]*) origin_fail "origin app id not configured" ;;
  esac
  case "${ORIGIN_INSTALLATION_ID}" in
    *[!A-Za-z0-9_-]*) origin_fail "origin installation not configured" ;;
  esac
  if [ "${#ORIGIN_INSTALLATION_ID}" -lt 2 ]; then
    origin_fail "origin installation not configured"
  fi
  origin_validate_repo "${APP_REPO:-}" || origin_fail "invalid repo"
  origin_validate_ref "${APP_REF:-}" || origin_fail "slot ref not configured"
  APP_REF=$(origin_lower "$APP_REF")
  branch=${APP_BRANCH:-main}
  origin_validate_branch "$branch" || origin_fail "invalid branch"
  case "${APP_SUBDIR:-}" in
    "") ;;
    *) origin_validate_relpath "$APP_SUBDIR" || origin_fail "invalid subdir" ;;
  esac
  [ -n "${APP_VERIFY_PATH:-}" ] || origin_fail "verify path not configured"
  case "${APP_REQUIRE_SUBMODULE:-}" in
    "") ;;
    *[!A-Za-z0-9._/-]*) origin_fail "invalid submodule" ;;
  esac
  repo_id=${ORIGIN_REPOSITORY_ID:-}
  if [ -n "$repo_id" ]; then
    case "$repo_id" in
      repo_[A-Za-z0-9]*) ;;
      *) origin_fail "invalid repository id" ;;
    esac
    case "$repo_id" in
      *[!A-Za-z0-9_]*) origin_fail "invalid repository id" ;;
    esac
  fi

  # Never reuse a developer session token that may already be in the environment.
  unset CURSOR_AUTH_TOKEN || true

  umask 077
  AUTH="$RUNNER_TEMP/origin-auth"
  rm -rf "$AUTH"
  mkdir -p "$AUTH"
  chmod 700 "$AUTH"
  cleanup_auth() {
    if [ -n "${AUTH:-}" ] && [ -d "$AUTH" ]; then
      rm -rf "$AUTH"
    fi
  }
  trap cleanup_auth EXIT

  KEY="$AUTH/app.pem"
  printf '%s\n' "$ORIGIN_APP_PRIVATE_KEY" > "$KEY"
  chmod 600 "$KEY"

  now=$(date +%s)
  header=$(printf '{"alg":"EdDSA","kid":"%s","typ":"JWT"}' "$ORIGIN_APP_ID" | origin_b64url)
  claims=$(printf '{"iss":"%s","aud":"origin-apps","iat":%d,"exp":%d}' "$ORIGIN_APP_ID" "$now" "$((now + 900))" | origin_b64url)
  signing_input="$AUTH/jwt.in"
  printf '%s.%s' "$header" "$claims" > "$signing_input"
  sig_raw="$AUTH/jwt.sig"
  if ! "$OSSL" pkeyutl -sign -rawin -in "$signing_input" -inkey "$KEY" > "$sig_raw"; then
    origin_fail "openssl ed25519 signer not available"
  fi
  signature=$(origin_b64url < "$sig_raw")
  app_jwt="$header.$claims.$signature"
  printf '::add-mask::%s\n' "$app_jwt" >&3
  rm -f "$KEY" "$signing_input" "$sig_raw"
  unset ORIGIN_APP_PRIVATE_KEY || true

  body=$(origin_token_body "$repo_id")
  resp_file="$AUTH/token.json"
  token_url="https://api.cursor.com/v1/origin/app/installations/${ORIGIN_INSTALLATION_ID}/access_tokens"
  set +e
  http=$(printf 'Authorization: Bearer %s\n' "$app_jwt" \
    | curl --proto '=https' --tlsv1.2 --max-time 60 -sS -o "$resp_file" -w '%{http_code}' \
        -X POST -H @- -H 'Content-Type: application/json' --data "$body" "$token_url")
  curl_st=$?
  set -e
  if [ "$curl_st" -ne 0 ]; then
    origin_fail "origin token request failed"
  fi
  if [ "$http" != "200" ]; then
    printf 'token http %s\n' "$http"
    if [ -f "$resp_file" ]; then
      sed -E 's/oit_[A-Za-z0-9._-]+/[redacted]/g' "$resp_file" || true
    fi
    origin_fail "origin token request rejected"
  fi
  token=$(jq -er '.token' "$resp_file")
  case "$token" in
    oit_[A-Za-z0-9]*) ;;
    *) origin_fail "origin token missing" ;;
  esac
  case "$token" in
    *[!A-Za-z0-9_-]*) origin_fail "origin token missing" ;;
  esac
  printf '::add-mask::%s\n' "$token" >&3
  TOK="$AUTH/token"
  printf '%s' "$token" > "$TOK"
  chmod 600 "$TOK"
  rm -f "$resp_file"
  unset token app_jwt signature || true
  export ORIGIN_TOKEN_FILE="$TOK"

  CRED_HELPER="$AUTH/cred.sh"
  cat > "$CRED_HELPER" <<'EOF'
#!/bin/bash
set -eu
op="${1:-get}"
[ "$op" = "get" ] || exit 0
proto=""
host=""
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && break
  case "$line" in
    protocol=*) proto="${line#protocol=}" ;;
    host=*) host="${line#host=}" ;;
  esac
done
[ "$proto" = "https" ] || exit 0
[ "$host" = "origin.cursor.com" ] || exit 0
[ -n "${ORIGIN_TOKEN_FILE:-}" ] && [ -f "$ORIGIN_TOKEN_FILE" ] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$(cat "$ORIGIN_TOKEN_FILE")"
EOF
  chmod 700 "$CRED_HELPER"

  ASKPASS="$AUTH/askpass.sh"
  printf '#!/bin/bash\nexit 1\n' > "$ASKPASS"
  chmod 700 "$ASKPASS"
  export GIT_TERMINAL_PROMPT=0
  export GIT_ASKPASS="$ASKPASS"
  export GIT_CONFIG_GLOBAL="$AUTH/empty-gitconfig"
  : > "$GIT_CONFIG_GLOBAL"
  export GIT_CONFIG_NOSYSTEM=1

  origin_git() {
    git \
      -c "safe.directory=*" \
      -c advice.detachedHead=false \
      -c credential.helper= \
      -c "credential.helper=${CRED_HELPER}" \
      -c credential.useHttpPath=true \
      "$@"
  }

  repo="$RUNNER_TEMP/src"
  rm -rf "$repo"
  mkdir -p "$repo"
  origin_git init -q "$repo"
  origin_git -C "$repo" remote add origin "https://origin.cursor.com/${APP_REPO}.git"

  ref_low=$(origin_lower "$APP_REF")
  fetched=0
  if [ "${#APP_REF}" -eq 40 ]; then
    set +e
    origin_git -C "$repo" fetch --no-tags --depth 1 origin "$APP_REF"
    fetch_st=$?
    set -e
    if [ "$fetch_st" -eq 0 ]; then
      origin_git -C "$repo" checkout -q --detach FETCH_HEAD
      fetched=1
    else
      printf 'direct sha fetch failed; trying branch\n'
    fi
  fi
  if [ "$fetched" -ne 1 ]; then
    if ! origin_git -C "$repo" fetch --no-tags origin "refs/heads/${branch}:refs/remotes/origin/${branch}"; then
      origin_fail "origin fetch failed"
    fi
    set +e
    chosen=$(origin_git -C "$repo" rev-list "refs/remotes/origin/${branch}" | origin_select_commit "$APP_REF" "$AUTH/matches")
    sel=$?
    set -e
    if [ "$sel" -ne 0 ]; then
      if [ "$sel" -eq 3 ]; then
        origin_fail "ref not unique on branch"
      fi
      origin_fail "ref not on branch"
    fi
    origin_git -C "$repo" checkout -q --detach "$chosen"
  fi

  got=$(origin_git -C "$repo" rev-parse HEAD)
  got_low=$(origin_lower "$got")
  case "$got_low" in
    "$ref_low"*) ;;
    *)
      printf 'head %s\n' "$got"
      origin_fail "commit mismatch"
      ;;
  esac
  if [ "${#APP_REF}" -eq 40 ] && [ "$got_low" != "$ref_low" ]; then
    printf 'head %s\n' "$got"
    origin_fail "commit mismatch"
  fi
  printf 'commit %s\n' "$got"
  origin_git -C "$repo" log -1 --format='commit %H %s'

  if [ -f "$repo/.gitmodules" ]; then
    git -C "$repo" config -f .gitmodules --get-regexp '^submodule\..*\.url$' > "$AUTH/sub-urls" || true
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      key=${line%% *}
      url=${line#* }
      new=$(origin_rewrite_submodule_url "$url")
      if [ "$new" != "$url" ]; then
        git -C "$repo" config -f .gitmodules "$key" "$new"
        printf 'rewrote submodule remote %s\n' "$key"
      fi
    done < "$AUTH/sub-urls"
    origin_git -C "$repo" submodule sync --recursive
    origin_git -C "$repo" submodule update --init --recursive
  fi

  sub_n=0
  needle=${APP_REQUIRE_SUBMODULE:-}
  needle_low=$(origin_lower "$needle")
  found_required=0
  : > "$AUTH/tree"
  # NUL-delimited records; the trailing empty read is ignored.
  git -C "$repo" ls-tree -r -z HEAD > "$AUTH/tree" || origin_fail "tree read failed"
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    [ -n "$rec" ] || continue
    mode=${rec%% *}
    rest=${rec#* }
    rest=${rest#* }
    sha=${rest%%$'\t'*}
    path=${rest#*$'\t'}
    [ "$mode" = "160000" ] || continue
    sub_n=$((sub_n + 1))
    if [ ! -d "$repo/$path/.git" ] && [ ! -f "$repo/$path/.git" ]; then
      printf 'submodule not checked out %s\n' "$path"
      origin_fail "submodule missing"
    fi
    got_sub=$(git -C "$repo/$path" rev-parse HEAD)
    if [ "$(origin_lower "$got_sub")" != "$(origin_lower "$sha")" ]; then
      printf 'pin %s got %s path %s\n' "$sha" "$got_sub" "$path"
      origin_fail "submodule pin mismatch"
    fi
    printf 'submodule %s %s\n' "$sha" "$path"
    path_low=$(origin_lower "$path")
    url_low=""
    if [ -f "$repo/.gitmodules" ]; then
      url_line=$(awk -v p="$path" '
        /^\[submodule / { sp=""; su="" }
        /^[ \t]*path[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); sp=$0 }
        /^[ \t]*url[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); su=$0 }
        sp == p && su != "" { print su; exit }
      ' "$repo/.gitmodules" || true)
      url_low=$(origin_lower "$url_line")
    fi
    if [ -n "$needle_low" ]; then
      case "$path_low" in
        *"$needle_low"*) found_required=1 ;;
      esac
      case "$url_low" in
        *"$needle_low"*) found_required=1 ;;
      esac
    fi
    case "$path_low$url_low" in
      *snes9x*) printf 'snes9x %s\n' "$sha" ;;
    esac
  done < "$AUTH/tree"
  printf 'submodules %s\n' "$sub_n"
  if [ -n "$needle_low" ] && [ "$found_required" -ne 1 ]; then
    origin_fail "required submodule missing"
  fi

  printf '%s' "$APP_VERIFY_PATH" | tr ',;' '\n\n' > "$AUTH/paths"
  verified=0
  while IFS= read -r p || [ -n "$p" ]; do
    p=$(printf '%s' "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$p" ] || continue
    origin_validate_relpath "$p" || origin_fail "invalid verify path"
    if [ ! -e "$repo/$p" ]; then
      printf 'missing verify entry\n'
      origin_fail "verify path missing"
    fi
    printf 'verified %s\n' "$p"
    verified=$((verified + 1))
  done < "$AUTH/paths"
  [ "$verified" -ge 1 ] || origin_fail "verify path not configured"

  if [ -n "${APP_SUBDIR:-}" ] && [ ! -d "$repo/$APP_SUBDIR" ]; then
    origin_fail "subdir missing"
  fi

  # Match the GitHub checkout: native projects skip Expo. SRC is set in Prepare.
  if [ ! -f "$SRC/package.json" ] && { [ -f "$SRC/project.yml" ] || compgen -G "$SRC/*.xcodeproj" >/dev/null; }; then
    echo "NATIVE=1" >> "$GITHUB_ENV"
    echo "✔ ok (native)" >&3
  else
    echo "NATIVE=0" >> "$GITHUB_ENV"
    echo "✔ ok" >&3
  fi
}

if [ "${ORIGIN_CHECKOUT_LIB:-}" != 1 ]; then
  origin_checkout_main
fi
