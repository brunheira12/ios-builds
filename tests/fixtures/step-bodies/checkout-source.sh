exec 3>&1 >>"$LOG" 2>&1; set -E; trap 'echo "✖ failed" >&3' ERR
K="$RUNNER_TEMP/dk"; umask 077; printf '%s\n' "$DEPLOY_KEY" > "$K"
GIT_SSH_COMMAND="ssh -i $K -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
  git clone -q --depth 1 "git@github.com:${APP_REPO}.git" "$RUNNER_TEMP/src"
rm -f "$K"
git -C "$RUNNER_TEMP/src" log -1 --format='commit %H %s'
# native Xcode project (xcodegen project.yml or committed .xcodeproj, no package.json) skips Expo/npm
if [ ! -f "$SRC/package.json" ] && { [ -f "$SRC/project.yml" ] || compgen -G "$SRC/*.xcodeproj" >/dev/null; }; then
  echo "NATIVE=1" >> "$GITHUB_ENV"; echo "✔ ok (native)" >&3
else
  echo "NATIVE=0" >> "$GITHUB_ENV"; echo "✔ ok" >&3
fi
