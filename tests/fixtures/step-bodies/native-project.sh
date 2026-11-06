exec 3>&1 >>"$LOG" 2>&1; set -E; trap 'echo "✖ failed" >&3' ERR
cd "$SRC"; . "$APP_ENV_FILE"
if [ -f project.yml ]; then
  command -v xcodegen || HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xcodegen
  xcodegen generate --spec project.yml
fi
PRJ=$(ls -d *.xcodeproj | head -n1)
NAME=$(basename "$PRJ" .xcodeproj); echo "::add-mask::$NAME" >&3
ruby -rxcodeproj -e '
  p = Xcodeproj::Project.open(ARGV[0])
  prof = { ENV["BUNDLE_ID"] => ENV["PROFILE_UUID"] }
  prof[ENV["WATCH_BUNDLE_ID"]] = ENV["WATCH_PROFILE_UUID"] if ENV["WATCH_BUNDLE_ID"].to_s != ""
  prof[ENV["EXT_BUNDLE_ID"]] = ENV["EXT_PROFILE_UUID"] if ENV["EXT_BUNDLE_ID"].to_s != ""
  types = ["com.apple.product-type.application", "com.apple.product-type.application.watchapp2-container",
           "com.apple.product-type.application.watchapp2", "com.apple.product-type.app-extension",
           "com.apple.product-type.watchkit2-extension", "com.apple.product-type.extensionkit-extension"]
  ta = (p.root_object.attributes["TargetAttributes"] ||= {})
  n = 0; ios = false; watch = false
  p.native_targets.select { |t| types.include?(t.product_type) }.each do |t|
    ios = true if t.product_type.end_with?("watchapp2-container")
    (ta[t.uuid] ||= {})["ProvisioningStyle"] = "Manual"
    t.build_configurations.each do |c|
      s = c.build_settings
      sdk = (s["SDKROOT"] || t.sdk.to_s)
      watch = true if sdk.start_with?("watchos")
      ios = true if sdk.start_with?("iphoneos")
      bid = s["PRODUCT_BUNDLE_IDENTIFIER"]
      uuid = prof[bid] or raise "no profile for target #{t.name}"
      s["CODE_SIGN_STYLE"] = "Manual"
      s["DEVELOPMENT_TEAM"] = ENV["TEAM"]
      s["CODE_SIGN_IDENTITY"] = "iPhone Distribution"
      s["CODE_SIGN_IDENTITY[sdk=iphoneos*]"] = "iPhone Distribution"
      s["CODE_SIGN_IDENTITY[sdk=watchos*]"] = "iPhone Distribution"
      s["PROVISIONING_PROFILE_SPECIFIER"] = uuid
      s["CURRENT_PROJECT_VERSION"] = ENV["BUILD_NUMBER"]
      n += 1
    end
  end
  raise "no app target" if n == 0
  p.save
  # watch-only apps ship inside an iOS container and archive as iOS; a bare watchOS project archives as watchOS
  File.write(ENV["GITHUB_ENV"], "DEST=generic/platform=#{(ios || !watch) ? "iOS" : "watchOS"}\n", mode: "a")' "$PRJ"
{ echo "SCHEME=$NAME"; echo "PRJ=$SRC/$PRJ"; } >> "$GITHUB_ENV"
find . -maxdepth 3 -name '*Info.plist' -not -path './build/*' | while read -r f; do /usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$f" || true; done
echo "✔ ok" >&3
