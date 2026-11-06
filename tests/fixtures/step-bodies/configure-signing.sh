exec 3>&1 >>"$LOG" 2>&1; set -E; trap 'echo "✖ failed" >&3' ERR
cd "$SRC/ios"
ruby -rxcodeproj -e '
  p = Xcodeproj::Project.open("#{ENV["SCHEME"]}.xcodeproj")
  ta = (p.root_object.attributes["TargetAttributes"] ||= {})
  n = 0
  p.native_targets.select { |t| t.product_type == "com.apple.product-type.application" }.each do |t|
    (ta[t.uuid] ||= {})["ProvisioningStyle"] = "Manual"
    t.build_configurations.each do |c|
      s = c.build_settings
      s["CODE_SIGN_STYLE"] = "Manual"
      s["DEVELOPMENT_TEAM"] = ENV["TEAM"]
      s["CODE_SIGN_IDENTITY"] = "iPhone Distribution"
      s["CODE_SIGN_IDENTITY[sdk=iphoneos*]"] = "iPhone Distribution"
      s["PROVISIONING_PROFILE_SPECIFIER"] = ENV["PROFILE_UUID"]
      s["CURRENT_PROJECT_VERSION"] = ENV["BUILD_NUMBER"]
      n += 1
    end
  end
  raise "no app target" if n == 0
  p.save'
echo "✔ ok" >&3
