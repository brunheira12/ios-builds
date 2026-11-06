exec 3>&1 >>"$LOG" 2>&1; set -E; trap 'echo "✖ failed" >&3' ERR
O="$RUNNER_TEMP/ExportOptions.plist"
cat > "$O" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>${TEAM}</string>
  <key>signingCertificate</key><string>${SIGN_SHA1}</string>
  <key>provisioningProfiles</key><dict><key>${BUNDLE_ID}</key><string>${PROFILE_UUID}</string>${WATCH_BUNDLE_ID:+<key>${WATCH_BUNDLE_ID}</key><string>${WATCH_PROFILE_UUID}</string>}${EXT_BUNDLE_ID:+<key>${EXT_BUNDLE_ID}</key><string>${EXT_PROFILE_UUID}</string>}</dict>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$RUNNER_TEMP/app.xcarchive" -exportPath "$RUNNER_TEMP/export" -exportOptionsPlist "$O"
ls -la "$RUNNER_TEMP/export"
echo "✔ ok ($(du -h "$RUNNER_TEMP"/export/*.ipa | cut -f1 | tr -d ' '))" >&3
