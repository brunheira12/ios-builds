exec 3>&1 >>"${LOG:-/dev/null}" 2>&1
[ -n "$KC" ] && security delete-keychain "$KC" || true
rm -rf "$HOME/.appstoreconnect" "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$RUNNER_TEMP/dk" "$RUNNER_TEMP/p.mobileprovision" "$RUNNER_TEMP/p.plist" "${APP_ENV_FILE:-}"
echo "✔ ok" >&3
