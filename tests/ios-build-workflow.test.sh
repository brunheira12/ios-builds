#!/usr/bin/env bash
# Linux-side checks for the unsigned Origin checkout and compile-only mode.
# No network, no secrets, no Xcode.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

bash -n scripts/origin-checkout.sh
bash -n scripts/compile-only.sh
bash -n tests/ios-build-workflow.test.sh

(
  ORIGIN_CHECKOUT_LIB=1
  # shellcheck disable=SC1091
  source scripts/origin-checkout.sh
  origin_validate_repo "jefferson-brunheira/super16"
  origin_validate_repo "owner/repo.git" && fail "accepted .git suffix"
  origin_validate_repo "https://origin.cursor.com/o/r" && fail "accepted url"
  origin_validate_repo "a/b/c" && fail "accepted extra slash"
  origin_validate_repo "o/r with space" && fail "accepted space"
  origin_validate_ref "9d4b832"
  origin_validate_ref "9d4b832aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" 
  origin_validate_ref "9d4b83" && fail "accepted short ref"
  origin_validate_ref "main" && fail "accepted branch as ref"
  origin_validate_branch "main"
  origin_validate_branch "feature/snes"
  origin_validate_branch "refs/heads/main" && fail "accepted refs/heads"
  origin_validate_branch ".." && fail "accepted dotdot"
  origin_validate_relpath "Super16.xcodeproj"
  origin_validate_relpath "ThirdParty/snes9x"
  origin_validate_relpath "/etc/passwd" && fail "accepted absolute"
  origin_validate_relpath "a/../../b" && fail "accepted dotdot path"
  [ "$(origin_token_body "")" = '{"scopes":["repository:contents:read"]}' ]
  [ "$(origin_token_body "repo_abc123")" = '{"scopes":["repository:contents:read"],"repositoryIds":["repo_abc123"]}' ]
  origin_validate_repository_id "r_01m6rdmrh3f7d9pprch6yff5eq"
  origin_validate_repository_id "repo_01k2ja2000e0080000000000q4"
  origin_validate_repository_id "repo_abc123"
  origin_validate_repository_id "repo_" && fail "accepted empty repository id body"
  origin_validate_repository_id "../etc" && fail "accepted path repository id"
  origin_validate_repository_id 'id"injection' && fail "accepted quoted repository id"
  tokdir=$(mktemp -d)
  documented='oit_2v8xkq4m1c7p9t3w5y0z6r4b'
  printf '{"token":"%s","expiresAt":"2026-08-01T10:30:00Z"}\n' "$documented" > "$tokdir/ok.json"
  decision=$(LC_ALL=en_US.UTF-8 origin_token_decision "$tokdir/ok.json" 200)
  case "$decision" in
    accept\ *) ;;
    *) fail "documented token rejected: $decision" ;;
  esac
  printf '%s\n' "$decision" | grep -F "$documented" && fail "decision leaked the token"
  dotted='oit_ab.cd+ef/gh=ij12'
  printf '{"token":"%s","expiresAt":"2026-08-01T10:30:00Z"}\n' "$dotted" > "$tokdir/dot.json"
  decision=$(origin_token_decision "$tokdir/dot.json" 200)
  case "$decision" in
    accept\ *) ;;
    *) fail "dotted token rejected: $decision" ;;
  esac
  printf '%s\n' "$decision" | grep -F 'prefix=yes' >/dev/null
  printf '%s\n' "$decision" | grep -F 'dot=yes' >/dev/null
  printf '%s\n' "$decision" | grep -F "$dotted" && fail "decision leaked dotted token"
  printf '{"token":"SENTINELTOKENVALUE","expiresAt":"2026-08-01T10:30:00Z"}\n' > "$tokdir/bad.json"
  set +e
  decision=$(origin_token_decision "$tokdir/bad.json" 200)
  sel=$?
  set -e
  [ "$sel" -ne 0 ]
  printf '%s\n' "$decision" | grep -F 'prefix=no' >/dev/null
  printf '%s\n' "$decision" | grep -F 'SENTINELTOKENVALUE' && fail "decision leaked a rejected token"
  printf '{"expiresAt":"2026-08-01T10:30:00Z"}\n' > "$tokdir/missing.json"
  set +e
  decision=$(origin_token_decision "$tokdir/missing.json" 200)
  sel=$?
  set -e
  [ "$sel" -ne 0 ]
  printf '%s\n' "$decision" | grep -F 'tokenType=null' >/dev/null
  printf '{"message":"Issuer is not authorized SENTINELTOKENVALUE"}\n' > "$tokdir/err.json"
  meta=$(origin_http_meta "$tokdir/err.json" 401)
  printf '%s\n' "$meta" | grep -F 'http=401' >/dev/null
  printf '%s\n' "$meta" | grep -F 'message=yes' >/dev/null
  printf '%s\n' "$meta" | grep -F 'code=none' >/dev/null
  printf '%s\n' "$meta" | grep -F 'SENTINELTOKENVALUE' && fail "http meta leaked response text"
  printf '%s\n' "$meta" | grep -F 'Issuer' && fail "http meta leaked the error message"
  rm -rf "$tokdir"
  [ "$(origin_rewrite_submodule_url "git@github.com:snes9xgit/snes9x.git")" = "https://github.com/snes9xgit/snes9x.git" ]
  [ "$(origin_rewrite_submodule_url "ssh://git@github.com/snes9xgit/snes9x.git")" = "https://github.com/snes9xgit/snes9x.git" ]
  [ "$(origin_rewrite_submodule_url "git@origin.cursor.com:jefferson-brunheira/super16.git")" = "https://origin.cursor.com/jefferson-brunheira/super16.git" ]
  same="https://github.com/snes9xgit/snes9x.git"
  [ "$(origin_rewrite_submodule_url "$same")" = "$same" ]
  tokenish="https://x-access-token:secret@origin.cursor.com/o/r.git"
  [ "$(origin_rewrite_submodule_url "$tokenish")" = "$tokenish" ] || fail "rewrite dropped a url it should leave unchanged"
  hits=$(mktemp)
  printf '%s\n' "abc1234aaaa" "deadbeefdead" | origin_select_commit "abc1234" "$hits" >/tmp/one-sha
  [ "$(cat /tmp/one-sha)" = "abc1234aaaa" ]
  set +e
  printf '%s\n' "abc1234aaaa" "abc1234bbbb" | origin_select_commit "ABC1234" "$hits" >/dev/null
  sel=$?
  set -e
  [ "$sel" -eq 3 ]
  set +e
  printf '%s\n' "deadbeef" | origin_select_commit "abc1234" "$hits" >/dev/null
  sel=$?
  set -e
  [ "$sel" -eq 2 ]
  rm -f "$hits" /tmp/one-sha
)

(
  COMPILE_ONLY_LIB=1
  # shellcheck disable=SC1091
  source scripts/compile-only.sh
  tmp=$(mktemp -d)
  printf 'SDKROOT = iphoneos;\n' > "$tmp/ios.pbxproj"
  [ "$(compile_only_destination "$tmp/ios.pbxproj" ios)" = "generic/platform=iOS" ]
  [ "$(compile_only_destination "$tmp/ios.pbxproj" simulator)" = "generic/platform=iOS Simulator" ]
  printf 'SDKROOT = watchos;\n' > "$tmp/watch.pbxproj"
  [ "$(compile_only_destination "$tmp/watch.pbxproj" ios)" = "generic/platform=watchOS" ]
  [ "$(compile_only_destination "$tmp/watch.pbxproj" simulator)" = "generic/platform=watchOS Simulator" ]
  printf 'SDKROOT = iphoneos;\nSDKROOT = watchos;\n' > "$tmp/both.pbxproj"
  [ "$(compile_only_destination "$tmp/both.pbxproj" ios)" = "generic/platform=iOS" ]
  [ "$(compile_only_sdk "generic/platform=iOS")" = "iphoneos" ]
  [ "$(compile_only_sdk "generic/platform=iOS Simulator")" = "iphonesimulator" ]
  [ "$(compile_only_sdk "generic/platform=watchOS")" = "watchos" ]
  [ "$(compile_only_sdk "generic/platform=watchOS Simulator")" = "watchsimulator" ]
  export SRC=/Users/runner/work/_temp/src
  export RUNNER_TEMP=/Users/runner/work/_temp
  cat > "$tmp/xcode.log" <<'EOF'
CompileC Super16/App.swift
/Users/runner/work/_temp/src/Super16/App.swift:10:5: error: cannot find 'ROM' in scope
    loadROM()
    ^~~~~~
ld: framework not found Foo
** BUILD FAILED **
/Users/runner/work/_temp/src/file.swift:1:1: error: BEGIN PRIVATE KEY
note oit_secretleak should drop
https://user:secret@origin.cursor.com/o/r
EOF
  got=$(compile_only_public_errors "$tmp/xcode.log")
  printf '%s\n' "$got" | grep -F "Super16/App.swift:10:5: error: cannot find 'ROM' in scope" >/dev/null
  printf '%s\n' "$got" | grep -F "ld: framework not found Foo" >/dev/null
  printf '%s\n' "$got" | grep -F "** BUILD FAILED **" >/dev/null
  printf '%s\n' "$got" | grep -F "loadROM" && fail "sanitizer leaked a source line"
  printf '%s\n' "$got" | grep -F "oit_" && fail "sanitizer leaked a token"
  printf '%s\n' "$got" | grep -F "BEGIN PRIVATE" && fail "sanitizer leaked a key"
  printf '%s\n' "$got" | grep -F "user:secret" && fail "sanitizer leaked a URL credential"
  printf '%s\n' "$got" | grep -F "/Users/runner" && fail "sanitizer left a runner path"
  rm -rf "$tmp"
)

# Credential helper answers only for Origin HTTPS and never stores the token.
(
  ORIGIN_CHECKOUT_LIB=1
  # shellcheck disable=SC1091
  source scripts/origin-checkout.sh
  dir=$(mktemp -d)
  printf '%s' 'oit_testtokenvalue0123' > "$dir/token"
  chmod 600 "$dir/token"
  helper=$dir/cred.sh
  sed -n '/^#!/,$p' scripts/origin-checkout.sh >/dev/null
  # Extract the helper the script writes by running the same heredoc body from the file.
  awk '
    BEGIN {p=0}
    /^  cat > "\$CRED_HELPER" <<'\''EOF'\''$/ {p=1; next}
    /^EOF$/ {if (p) exit}
    p {print}
  ' scripts/origin-checkout.sh > "$helper"
  chmod 700 "$helper"
  export ORIGIN_TOKEN_FILE="$dir/token"
  github=$(printf 'protocol=https\nhost=github.com\n\n' | "$helper" get || true)
  [ -z "$github" ]
  origin=$(printf 'protocol=https\nhost=origin.cursor.com\n\n' | "$helper" get)
  printf '%s\n' "$origin" | grep -F 'username=x-access-token' >/dev/null
  printf '%s\n' "$origin" | grep -F 'password=oit_testtokenvalue0123' >/dev/null
  stored=$(printf 'protocol=https\nhost=origin.cursor.com\n' | "$helper" store || true)
  [ -z "$stored" ]
  [ "$(cat "$dir/token")" = "oit_testtokenvalue0123" ]
  rm -rf "$dir"
)

build_fixture() {
  fix=$1
  sub=$fix/sub
  parent=$fix/parent
  git init -q -b main "$sub"
  echo 'int snes_pin;' > "$sub/snes.c"
  git -C "$sub" add snes.c
  git -C "$sub" -c user.email=test@example.com -c user.name=test commit -q -m snes
  git clone --bare -q "$sub" "$fix/sub.git"
  git init -q -b main "$parent"
  mkdir -p "$parent/Super16.xcodeproj"
  printf '// Super16\n' > "$parent/Super16.xcodeproj/project.pbxproj"
  git -C "$parent" add Super16.xcodeproj/project.pbxproj
  git -C "$parent" -c user.email=test@example.com -c user.name=test commit -q -m app
  git -C "$parent" -c protocol.file.allow=always submodule add -q "$fix/sub.git" ThirdParty/snes9x
  git -C "$parent" config -f .gitmodules submodule.ThirdParty/snes9x.url 'git@github.com:snes9xgit/snes9x.git'
  git -C "$parent" add .gitmodules
  git -C "$parent" -c user.email=test@example.com -c user.name=test commit -q -m 'pin snes9x'
  git clone --bare -q "$parent" "$fix/parent.git"
  git -C "$parent" rev-parse HEAD
}

install_mocks() {
  bindir=$1
  cat > "$bindir/git" <<'PY'
#!/usr/bin/env python3
import os, sys, subprocess
REAL = "/usr/bin/git"
argv = sys.argv[1:]
with open(os.environ["MOCK_GIT_LOG"], "a", encoding="utf-8") as fh:
    fh.write("\0".join(argv) + "\n")
blob = "\n".join(argv)
for banned in ("oit_", "BEGIN PRIVATE", "x-access-token"):
    if banned in blob:
        sys.stderr.write("secret in git argv\n")
        sys.exit(9)
args = argv
cfgs = []
cwd = None
i = 0
while i < len(args):
    a = args[i]
    if a == "-c" and i + 1 < len(args):
        cfgs.append(args[i + 1])
        i += 2
        continue
    if a == "-C" and i + 1 < len(args):
        cwd = args[i + 1]
        i += 2
        continue
    break
rest = args[i:]
sub = rest[0] if rest else ""

def real(extra, git_args):
    cmd = [REAL, "-c", "safe.directory=*"]
    if extra:
        cmd += ["-C", extra]
    cmd += git_args
    return subprocess.call(cmd)

if sub == "fetch":
    url = subprocess.check_output([REAL, "-C", cwd, "remote", "get-url", "origin"], text=True).strip()
    with open(os.environ["MOCK_GIT_URLS"], "a", encoding="utf-8") as fh:
        fh.write(url + "\n")
    if "@" in url.split("://", 1)[-1].split("/")[0]:
        sys.stderr.write("token leaked into remote url\n")
        sys.exit(9)
    if "--depth" in rest and os.environ.get("MOCK_FAIL_DIRECT") == "1":
        sys.stderr.write("mock direct fetch refused\n")
        sys.exit(128)
    fetch_args = ["fetch", "--no-tags", os.environ["MOCK_ORIGIN_BARE"]]
    if "--depth" in rest:
        di = rest.index("--depth")
        fetch_args += ["--depth", rest[di + 1]]
    fetch_args.append(rest[-1])
    sys.exit(real(cwd, fetch_args))

if sub == "submodule" and len(rest) > 1 and rest[1] == "update":
    text = open(os.path.join(cwd, ".gitmodules"), encoding="utf-8").read().splitlines()
    paths = []
    for line in text:
        stripped = line.strip()
        if stripped.startswith("path"):
            paths.append(stripped.split("=", 1)[1].strip())
    for path in paths:
        ls = subprocess.check_output([REAL, "-C", cwd, "ls-tree", "HEAD", path], text=True).strip()
        sha = ls.split()[2]
        dest = os.path.join(cwd, path)
        if os.path.exists(dest):
            subprocess.check_call(["rm", "-rf", dest])
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        subprocess.check_call([REAL, "clone", "--no-checkout", os.environ["MOCK_SUBMODULE_BARE"], dest])
        subprocess.check_call([REAL, "-C", dest, "checkout", "--detach", sha])
    sys.exit(0)

sys.exit(real(cwd, rest))
PY
  cat > "$bindir/curl" <<'PY'
#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
stdin = sys.stdin.read()
blob = "\n".join(args)
if "BEGIN PRIVATE" in blob or "oit_" in blob:
    sys.stderr.write("secret in curl argv\n")
    sys.exit(9)
out = None
data = None
url = None
i = 0
while i < len(args):
    a = args[i]
    if a == "-o" and i + 1 < len(args):
        out = args[i + 1]
        i += 2
        continue
    if a == "--data" and i + 1 < len(args):
        data = args[i + 1]
        i += 2
        continue
    if a.startswith("http"):
        url = a
    i += 1
with open(os.environ["MOCK_CURL_LOG"], "a", encoding="utf-8") as fh:
    fh.write("URL " + (url or "") + "\n")
    fh.write("DATA " + (data or "") + "\n")
    fh.write("STDIN " + stdin + "\n")
code = os.environ.get("MOCK_CURL_CODE", "200")
body = os.environ.get(
    "MOCK_CURL_BODY",
    '{"token":"oit_testtokenvalue0123","expiresAt":"2099-01-01T00:00:00Z"}',
)
if out:
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(body)
sys.stdout.write(code)
sys.exit(0)
PY
  chmod 700 "$bindir/git" "$bindir/curl"
}

run_checkout() {
  work=$1
  sha=$2
  ref=$3
  bindir=$4
  bare=$5
  subbare=$6
  mkdir -p "$work"
  env_file=$work/github.env
  : > "$env_file"
  public=$work/public.txt
  private=$work/private.txt
  gitlog=$work/git.log
  urls=$work/urls.txt
  curllog=$work/curl.log
  : > "$gitlog"; : > "$urls"; : > "$curllog"
  key=$work/app.pem
  openssl genpkey -algorithm ED25519 -out "$key" >/dev/null 2>&1
  pub=$work/app.pub
  openssl pkey -in "$key" -pubout -out "$pub" >/dev/null 2>&1
  pem=$(cat "$key")
  set +e
  PATH="$bindir:$PATH" \
    RUNNER_TEMP="$work" \
    GITHUB_ENV="$env_file" \
    SRC="$work/src/" \
    APP_REPO=jefferson-brunheira/super16 \
    APP_REF="$ref" \
    APP_BRANCH=main \
    APP_SUBDIR= \
    APP_VERIFY_PATH="${APP_VERIFY_PATH:-Super16.xcodeproj}" \
    APP_REQUIRE_SUBMODULE="${APP_REQUIRE_SUBMODULE:-snes9x}" \
    ORIGIN_APP_ID=app_test1234 \
    ORIGIN_INSTALLATION_ID=inst_test1234 \
    ORIGIN_APP_PRIVATE_KEY="$pem" \
    ORIGIN_REPOSITORY_ID="${ORIGIN_REPOSITORY_ID:-}" \
    MOCK_GIT_LOG="$gitlog" \
    MOCK_GIT_URLS="$urls" \
    MOCK_CURL_LOG="$curllog" \
    MOCK_ORIGIN_BARE="$bare" \
    MOCK_SUBMODULE_BARE="$subbare" \
    MOCK_FAIL_DIRECT="${MOCK_FAIL_DIRECT:-}" \
    MOCK_CURL_CODE="${MOCK_CURL_CODE:-200}" \
    MOCK_CURL_BODY="${MOCK_CURL_BODY:-}" \
    bash scripts/origin-checkout.sh >"$private" 2>&1 3>"$public"
  st=$?
  set -e
  printf '%s\n' "$st" > "$work/status"
  printf '%s\n' "$pub" > "$work/pubpath"
}

assert_no_secret_leak() {
  work=$1
  token=oit_testtokenvalue0123
  # Mask commands are the only public lines allowed to carry the JWT or token.
  awk 'index($0, "::add-mask::") != 1' "$work/public.txt" > "$work/public-visible.txt"
  if grep -F "$token" "$work/public-visible.txt" >/dev/null; then
    fail "token visible on the public log"
  fi
  if grep -F "BEGIN PRIVATE" "$work/public-visible.txt" "$work/private.txt" "$work/git.log" "$work/curl.log" >/dev/null; then
    fail "private key leaked into logs"
  fi
  if grep -F "$token" "$work/git.log" "$work/curl.log" "$work/private.txt" >/dev/null; then
    fail "token leaked into git argv, curl argv, or the build log"
  fi
  if [ -d "$work/origin-auth" ]; then
    fail "origin auth directory was left behind"
  fi
}

fix=$(mktemp -d)
sha=$(build_fixture "$fix")
bindir=$(mktemp -d)
install_mocks "$bindir"

runner=$(mktemp -d)
ORIGIN_REPOSITORY_ID=repo_abc123 MOCK_CURL_BODY='{"token":"oit_testtokenvalue0123","expiresAt":"2099-01-01T00:00:00Z"}' \
  run_checkout "$runner" "$sha" "$sha" "$bindir" "$fix/parent.git" "$fix/sub.git"
[ "$(cat "$runner/status")" = "0" ] || { echo "---- private ----"; cat "$runner/private.txt"; echo "---- public ----"; cat "$runner/public.txt"; fail "full sha checkout failed"; }
grep -F 'NATIVE=1' "$runner/github.env" >/dev/null
grep -F "commit $sha" "$runner/private.txt" >/dev/null
grep -F "snes9x " "$runner/private.txt" >/dev/null
grep -F "submodules 1" "$runner/private.txt" >/dev/null
grep -F "verified Super16.xcodeproj" "$runner/private.txt" >/dev/null
grep -F "rewrote submodule remote" "$runner/private.txt" >/dev/null
grep -F 'https://origin.cursor.com/jefferson-brunheira/super16.git' "$runner/urls.txt" >/dev/null
grep -F 'repository:contents:read' "$runner/curl.log" >/dev/null
grep -F 'repositoryIds' "$runner/curl.log" >/dev/null
grep -F 'repo_abc123' "$runner/curl.log" >/dev/null
if grep -F 'repository:contents:write' "$runner/curl.log" >/dev/null; then
  fail "token requested write scope"
fi
# JWT claims and signature.
python3 - "$runner" <<'PY'
import base64, json, pathlib, subprocess, sys
runner = pathlib.Path(sys.argv[1])
stdin = (runner / "curl.log").read_text()
line = [l for l in stdin.splitlines() if l.startswith("STDIN ")][0]
bearer = line.split("Bearer ", 1)[1].strip()
header_b, payload_b, sig_b = bearer.split(".")
def dec(s):
    s += "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s)
header = json.loads(dec(header_b))
payload = json.loads(dec(payload_b))
assert header["alg"] == "EdDSA" and header["kid"] == "app_test1234" and header["typ"] == "JWT"
assert payload["iss"] == "app_test1234" and payload["aud"] == "origin-apps"
assert payload["exp"] - payload["iat"] == 900
pub = (runner / "pubpath").read_text().strip()
data = runner / "jwt.dat"
sig = runner / "jwt.sig"
data.write_bytes(f"{header_b}.{payload_b}".encode())
sig.write_bytes(dec(sig_b))
subprocess.check_call([
    "openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pub,
    "-rawin", "-in", str(data), "-sigfile", str(sig),
], stdout=subprocess.DEVNULL)
print("jwt ok")
PY
visible=$(awk 'index($0, "::add-mask::") != 1' "$runner/public.txt")
[ "$visible" = "✔ ok (native)" ] || fail "public log was: $visible"
if grep -F "$sha" "$runner/public.txt" >/dev/null; then
  # The SHA must not be required on the public log. Mask lines do not contain it.
  if awk 'index($0, "::add-mask::") != 1 && index($0, "'"$sha"'") { found=1 } END { exit(found?0:1) }' "$runner/public.txt"; then
    fail "commit sha leaked to the public log"
  fi
fi
assert_no_secret_leak "$runner"
if grep -F "x-access-token" "$runner/src/.git/config" >/dev/null; then
  fail "token stored in git config"
fi
grep -F 'url = https://github.com/snes9xgit/snes9x.git' "$runner/src/.gitmodules" >/dev/null
runner_r=$(mktemp -d)
ORIGIN_REPOSITORY_ID='r_01m6rdmrh3f7d9pprch6yff5eq' \
  MOCK_CURL_BODY='{"token":"oit_testtokenvalue0123","expiresAt":"2099-01-01T00:00:00Z"}' \
  run_checkout "$runner_r" "$sha" "$sha" "$bindir" "$fix/parent.git" "$fix/sub.git"
[ "$(cat "$runner_r/status")" = "0" ] || { cat "$runner_r/private.txt"; cat "$runner_r/public.txt"; fail "Get Repo r_ id was rejected"; }
grep -F 'r_01m6rdmrh3f7d9pprch6yff5eq' "$runner_r/curl.log" >/dev/null
grep -F 'repository:contents:read' "$runner_r/curl.log" >/dev/null
if grep -F 'repository:contents:write' "$runner_r/curl.log" >/dev/null; then
  fail "r_ id token requested write scope"
fi
assert_no_secret_leak "$runner_r"
runner_badid=$(mktemp -d)
ORIGIN_REPOSITORY_ID='../not-an-id' \
  MOCK_CURL_BODY='{"token":"oit_testtokenvalue0123","expiresAt":"2099-01-01T00:00:00Z"}' \
  run_checkout "$runner_badid" "$sha" "$sha" "$bindir" "$fix/parent.git" "$fix/sub.git"
[ "$(cat "$runner_badid/status")" != "0" ]
grep -F "invalid repository id" "$runner_badid/public.txt" >/dev/null
if [ -s "$runner_badid/curl.log" ]; then
  fail "invalid repository id still called the token API"
fi
sub_head=$(git -C "$runner/src/ThirdParty/snes9x" rev-parse HEAD)
pin=$(git -C "$runner/src" ls-tree HEAD ThirdParty/snes9x | awk '{print $3}')
[ "$sub_head" = "$pin" ] || fail "snes9x pin was not checked out"

# Abbreviated ref, and a refused direct SHA fetch falls back to the branch.
runner7=$(mktemp -d)
MOCK_CURL_BODY='{"token":"oit_testtokenvalue0123","expiresAt":"2099-01-01T00:00:00Z"}' \
  ORIGIN_REPOSITORY_ID= \
  run_checkout "$runner7" "$sha" "${sha:0:7}" "$bindir" "$fix/parent.git" "$fix/sub.git"
[ "$(cat "$runner7/status")" = "0" ] || { cat "$runner7/private.txt"; fail "short ref checkout failed"; }
grep -F "commit $sha" "$runner7/private.txt" >/dev/null
assert_no_secret_leak "$runner7"

runnerfb=$(mktemp -d)
MOCK_FAIL_DIRECT=1 MOCK_CURL_BODY='{"token":"oit_testtokenvalue0123","expiresAt":"2099-01-01T00:00:00Z"}' \
  run_checkout "$runnerfb" "$sha" "$sha" "$bindir" "$fix/parent.git" "$fix/sub.git"
[ "$(cat "$runnerfb/status")" = "0" ] || { cat "$runnerfb/private.txt"; fail "branch fallback failed"; }
grep -F "direct sha fetch failed" "$runnerfb/private.txt" >/dev/null
grep -F "commit $sha" "$runnerfb/private.txt" >/dev/null

# Rejected mint: public status only, response token redacted in the private log.
runner401=$(mktemp -d)
MOCK_CURL_CODE=401 MOCK_CURL_BODY='{"message":"Issuer is not authorized oit_secretleak"}' \
  run_checkout "$runner401" "$sha" "$sha" "$bindir" "$fix/parent.git" "$fix/sub.git"
[ "$(cat "$runner401/status")" != "0" ]
grep -F "origin token request rejected" "$runner401/public.txt" >/dev/null
grep -F "http=401" "$runner401/public.txt" >/dev/null
grep -F "message=yes" "$runner401/public.txt" >/dev/null
if grep -F "oit_secretleak" "$runner401/public.txt" "$runner401/private.txt" >/dev/null; then
  fail "rejected token body leaked"
fi
if grep -F "Issuer is not authorized" "$runner401/public.txt" "$runner401/private.txt" >/dev/null; then
  fail "rejected response text leaked"
fi
assert_no_secret_leak "$runner401"

runner_miss=$(mktemp -d)
APP_VERIFY_PATH=Missing.xcodeproj APP_REQUIRE_SUBMODULE= \
  MOCK_CURL_BODY='{"token":"oit_testtokenvalue0123","expiresAt":"2099-01-01T00:00:00Z"}' \
  run_checkout "$runner_miss" "$sha" "$sha" "$bindir" "$fix/parent.git" "$fix/sub.git"
[ "$(cat "$runner_miss/status")" != "0" ]
grep -F "verify path missing" "$runner_miss/public.txt" >/dev/null
if grep -F "Missing.xcodeproj" "$runner_miss/public.txt" >/dev/null; then
  fail "missing path was printed publicly"
fi

runner_sub=$(mktemp -d)
APP_VERIFY_PATH=Super16.xcodeproj APP_REQUIRE_SUBMODULE=not-a-real-core \
  MOCK_CURL_BODY='{"token":"oit_testtokenvalue0123","expiresAt":"2099-01-01T00:00:00Z"}' \
  run_checkout "$runner_sub" "$sha" "$sha" "$bindir" "$fix/parent.git" "$fix/sub.git"
[ "$(cat "$runner_sub/status")" != "0" ]
grep -F "required submodule missing" "$runner_sub/public.txt" >/dev/null

# Compile-only invokes xcodebuild build and publishes sanitized errors.
comp=$(mktemp -d)
mkdir -p "$comp/src/Super16.xcodeproj" "$comp/bin"
printf 'SDKROOT = iphoneos;\n' > "$comp/src/Super16.xcodeproj/project.pbxproj"
cat > "$comp/bin/xcodebuild" <<'PY'
#!/usr/bin/env python3
import os, pathlib, sys
path = pathlib.Path(os.environ["XCODE_ARGS"])
path.write_text("\n".join(sys.argv[1:]) + "\n")
src = os.environ["SRC"].rstrip("/")
sys.stdout.write(
    src + "/Super16/App.swift:4:1: error: cannot find 'start' in scope\n"
    "start()\n"
    "^~~~~\n"
    "** BUILD FAILED **\n"
)
sys.exit(65)
PY
chmod 700 "$comp/bin/xcodebuild"
public=$comp/public.txt
set +e
PATH="$comp/bin:$PATH" \
  SRC="$comp/src" \
  RUNNER_TEMP="$comp" \
  BUILD_KIND=native \
  APP_SCHEME=Super16 \
  COMPILE_DESTINATION=ios \
  XCODE_ARGS="$comp/args.txt" \
  bash scripts/compile-only.sh >"$comp/private.txt" 2>&1 3>"$public"
st=$?
set -e
[ "$st" = "65" ] || fail "compile-only exit was $st"
grep -F "xcodebuild exit 65" "$public" >/dev/null
grep -F "Super16/App.swift:4:1: error: cannot find 'start' in scope" "$public" >/dev/null
if grep -F "start()" "$public" >/dev/null; then
  fail "compile public log included source"
fi
args=$(cat "$comp/args.txt")
printf '%s\n' "$args" | grep -F "CODE_SIGNING_ALLOWED=NO" >/dev/null
printf '%s\n' "$args" | grep -F "CODE_SIGNING_REQUIRED=NO" >/dev/null
printf '%s\n' "$args" | grep -F "generic/platform=iOS" >/dev/null
printf '%s\n' "$args" | grep -F "iphoneos" >/dev/null
printf '%s\n' "$args" | grep -x "build" >/dev/null
if printf '%s\n' "$args" | grep -E '^(archive|test)$' >/dev/null; then
  fail "compile-only ran archive or test"
fi
if printf '%s\n' "$args" | grep -F "CODE_SIGN_IDENTITY" >/dev/null; then
  fail "compile-only overrode the signing identity"
fi

python3 tests/check_workflow.py
printf 'ok\n'
