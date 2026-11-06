exec 3>&1 >>"$LOG" 2>&1; set -E; trap 'echo "✖ failed" >&3' ERR
cd "$SRC/ios"; . "$APP_ENV_FILE"
xcodebuild -workspace "$SCHEME.xcworkspace" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$RUNNER_TEMP/app.xcarchive" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KC" archive
echo "✔ ok" >&3
