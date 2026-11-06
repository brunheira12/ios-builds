#!/usr/bin/env bash
# Compile-only xcodebuild for ios-build.
#
# Does not import signing certificates, provisioning profiles, or an App Store
# Connect key. Does not create an xcarchive, export, upload, boot a simulator, or launch the
# app. Project signing settings are left as committed; the build overrides only
# CODE_SIGNING_ALLOWED and CODE_SIGNING_REQUIRED.
#
# Full compiler output stays on stdout (the encrypted job log). fd 3 receives
# the exit code and sanitized error lines.
#
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

compile_fail() {
  printf '%s\n' "$1" >&3
  exit 1
}

compile_only_strip_prefix() {
  line=$1
  prefix=$2
  if [ -z "$prefix" ]; then
    printf '%s\n' "$line"
    return
  fi
  while :; do
    case "$line" in
      *"$prefix"*)
        prev=$line
        left=${line%%"$prefix"*}
        right=${line#*"$prefix"}
        line="${left}${right}"
        [ "$line" = "$prev" ] && break
        ;;
      *)
        break
        ;;
    esac
  done
  printf '%s\n' "$line"
}

compile_only_relativize() {
  line=$1
  src=${SRC-}
  src=${src%/}
  tmp=${RUNNER_TEMP-}
  tmp=${tmp%/}
  if [ -n "${src:-}" ]; then
    line=$(compile_only_strip_prefix "$line" "$src/")
    line=$(compile_only_strip_prefix "$line" "/private${src}/")
  fi
  if [ -n "${tmp:-}" ]; then
    line=$(compile_only_strip_prefix "$line" "$tmp/")
    line=$(compile_only_strip_prefix "$line" "/private${tmp}/")
  fi
  printf '%s\n' "$line"
}

# Read a pbxproj and print the generic destination. ios|simulator selects the
# SDK family. A project that mentions watchos and not iphoneos is watch-only;
# anything else (including an iOS app that embeds watchOS) stays on iOS.
compile_only_destination() {
  pbx=$1
  mode=$2
  watch=0
  ios=0
  if grep -q 'watchos' "$pbx"; then
    watch=1
  fi
  if grep -q 'iphoneos' "$pbx"; then
    ios=1
  fi
  platform="iOS"
  if [ "$watch" -eq 1 ] && [ "$ios" -eq 0 ]; then
    platform="watchOS"
  fi
  if [ "$mode" = "simulator" ]; then
    printf 'generic/platform=%s Simulator\n' "$platform"
  else
    printf 'generic/platform=%s\n' "$platform"
  fi
}

compile_only_sdk() {
  case "$1" in
    "generic/platform=iOS") printf 'iphoneos\n' ;;
    "generic/platform=iOS Simulator") printf 'iphonesimulator\n' ;;
    "generic/platform=watchOS") printf 'watchos\n' ;;
    "generic/platform=watchOS Simulator") printf 'watchsimulator\n' ;;
    *) return 1 ;;
  esac
}

compile_only_public_errors() {
  file=$1
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if [ "${#line}" -gt 400 ]; then
      line=${line:0:400}
    fi
    case "$line" in
      *"BEGIN PRIVATE"*|*"BEGIN CERTIFICATE"*|*"BEGIN RSA"*|*oit_*|*ghp_*|*github_pat_*|*password=*|*PASSWORD=*)
        continue
        ;;
    esac
    case "$line" in
      *"://"*@*) continue ;;
    esac
    line=$(compile_only_relativize "$line")
    case "$line" in
      *": error:"*|*"fatal error:"*|*"Undefined symbols"*|*"undefined symbol"*|*"ld: "*|*"clang: "*|*"** BUILD FAILED"*|*"** BUILD SUCCEEDED"*|*"The following build commands failed"*)
        printf '%s\n' "$line"
        n=$((n + 1))
        if [ "$n" -ge 40 ]; then
          break
        fi
        ;;
    esac
  done < "$file"
}

compile_only_main() {
  if ! { true >&3; } 2>/dev/null; then
    exec 3>&1
  fi
  : "${SRC:?}"
  : "${RUNNER_TEMP:?}"
  : "${BUILD_KIND:?}"
  mode=${COMPILE_DESTINATION:-ios}
  case "$mode" in
    ios|simulator) ;;
    *) compile_fail "invalid compile destination" ;;
  esac
  if [ -n "${APP_ENV_FILE:-}" ] && [ -f "$APP_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$APP_ENV_FILE"
  fi

  out="$RUNNER_TEMP/xcodebuild.out"
  : > "$out"

  if [ "$BUILD_KIND" = "native" ]; then
    cd "$SRC"
    if [ -f project.yml ]; then
      command -v xcodegen >/dev/null 2>&1 || HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xcodegen
      xcodegen generate --spec project.yml
    fi
    prj=""
    scheme=""
    if [ -n "${APP_SCHEME:-}" ]; then
      case "$APP_SCHEME" in
        *[!A-Za-z0-9._+-]*) compile_fail "invalid scheme" ;;
      esac
      scheme=$APP_SCHEME
    fi
    for cand in *.xcodeproj; do
      [ -d "$cand" ] || continue
      if [ -n "$scheme" ] && [ "$cand" = "${scheme}.xcodeproj" ]; then
        prj=$cand
        break
      fi
      if [ -z "$prj" ]; then
        prj=$cand
      fi
    done
    [ -n "$prj" ] && [ -d "$prj" ] || compile_fail "xcodeproj missing"
    if [ -z "$scheme" ]; then
      scheme=$(basename "$prj" .xcodeproj)
    fi
    pbx="$prj/project.pbxproj"
    [ -f "$pbx" ] || compile_fail "project file missing"
    dest=$(compile_only_destination "$pbx" "$mode")
    sdk=$(compile_only_sdk "$dest") || compile_fail "invalid compile destination"
    printf 'compile project=%s scheme=%s destination=%s sdk=%s\n' "$prj" "$scheme" "$dest" "$sdk"
    set +e
    xcodebuild -project "$prj" -scheme "$scheme" -configuration Release \
      -destination "$dest" -sdk "$sdk" \
      build \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      >"$out" 2>&1
    st=$?
    set -e
  elif [ "$BUILD_KIND" = "workspace" ]; then
    [ -n "${SCHEME:-}" ] || compile_fail "scheme missing"
    cd "$SRC/ios"
    if [ "$mode" = "simulator" ]; then
      dest="generic/platform=iOS Simulator"
    else
      dest="generic/platform=iOS"
    fi
    sdk=$(compile_only_sdk "$dest") || compile_fail "invalid compile destination"
    printf 'compile workspace=%s scheme=%s destination=%s sdk=%s\n' "$SCHEME.xcworkspace" "$SCHEME" "$dest" "$sdk"
    set +e
    xcodebuild -workspace "$SCHEME.xcworkspace" -scheme "$SCHEME" -configuration Release \
      -destination "$dest" -sdk "$sdk" \
      build \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      >"$out" 2>&1
    st=$?
    set -e
  else
    compile_fail "invalid build kind"
  fi

  cat "$out"
  if [ "$st" -ne 0 ]; then
    printf 'xcodebuild exit %s\n' "$st" >&3
    compile_only_public_errors "$out" >&3 || true
    exit "$st"
  fi
  printf '✔ ok\n' >&3
}

if [ "${COMPILE_ONLY_LIB:-}" != 1 ]; then
  compile_only_main
fi
