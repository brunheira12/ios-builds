[[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "invalid build number"; exit 1; }
[ -n "$APP_REPO" ] || { echo "slot not configured"; exit 1; }
for v in "$APP_REPO" "${APP_REPO#*/}" "${APP_REPO%%/*}"; do echo "::add-mask::$v"; done
echo "LOG=$RUNNER_TEMP/build.log" >> "$GITHUB_ENV"
echo "SRC=$RUNNER_TEMP/src/$APP_SUBDIR" >> "$GITHUB_ENV"
: > "$RUNNER_TEMP/build.log"
# optional per-app build-time env (KEY=VALUE lines); values are masked and kept in a 0600 file
E="$RUNNER_TEMP/app.env"; (umask 077; : > "$E")
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"; [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
  v="${line#*=}"; [ -n "$v" ] && echo "::add-mask::$v"
  printf 'export %s=%q\n' "${line%%=*}" "$v" >> "$E"
done <<< "$APP_ENV"
echo "APP_ENV_FILE=$E" >> "$GITHUB_ENV"
echo "✔ ok"
