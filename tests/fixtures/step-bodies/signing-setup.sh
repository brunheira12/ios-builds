exec 3>&1 >>"$LOG" 2>&1; set -E; trap 'echo "✖ failed" >&3' ERR
umask 077; T="$RUNNER_TEMP"
KCP=$(openssl rand -hex 24); echo "::add-mask::$KCP" >&3
KC="$T/sign.keychain-db"
security create-keychain -p "$KCP" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KCP" "$KC"
printf '%s' "$P12_B64" | base64 --decode > "$T/d.p12"
security import "$T/d.p12" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KC"
rm -f "$T/d.p12"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCP" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
SHA1=$(security find-identity -v -p codesigning "$KC" | awk 'NR==1{print $2}')
[ -n "$SHA1" ]; echo "::add-mask::$SHA1" >&3
printf '%s' "$PROFILE_B64" | base64 --decode > "$T/p.mobileprovision"
security cms -D -i "$T/p.mobileprovision" > "$T/p.plist"
UUID=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$T/p.plist")
APPID=$(/usr/libexec/PlistBuddy -c 'Print Entitlements:application-identifier' "$T/p.plist")
BUNDLE_ID="${APPID#*.}"
for v in "$UUID" "$BUNDLE_ID"; do echo "::add-mask::$v" >&3; done
for d in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  mkdir -p "$d"; cp "$T/p.mobileprovision" "$d/$UUID.mobileprovision"; done
{ echo "KC=$KC"; echo "SIGN_SHA1=$SHA1"; echo "PROFILE_UUID=$UUID"; echo "BUNDLE_ID=$BUNDLE_ID"; } >> "$GITHUB_ENV"
if [ -n "$WATCH_PROFILE_B64" ]; then
  printf '%s' "$WATCH_PROFILE_B64" | base64 --decode > "$T/w.mobileprovision"
  security cms -D -i "$T/w.mobileprovision" > "$T/w.plist"
  WUUID=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$T/w.plist")
  WAPPID=$(/usr/libexec/PlistBuddy -c 'Print Entitlements:application-identifier' "$T/w.plist")
  WBUNDLE_ID="${WAPPID#*.}"
  for v in "$WUUID" "$WBUNDLE_ID"; do echo "::add-mask::$v" >&3; done
  for d in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    cp "$T/w.mobileprovision" "$d/$WUUID.mobileprovision"; done
  rm -f "$T/w.mobileprovision" "$T/w.plist"
  { echo "WATCH_PROFILE_UUID=$WUUID"; echo "WATCH_BUNDLE_ID=$WBUNDLE_ID"; } >> "$GITHUB_ENV"
fi
# optional 3rd profile for an app extension (e.g. a watchOS WidgetKit complication)
if [ -n "$EXT_PROFILE_B64" ]; then
  printf '%s' "$EXT_PROFILE_B64" | base64 --decode > "$T/x.mobileprovision"
  security cms -D -i "$T/x.mobileprovision" > "$T/x.plist"
  XUUID=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$T/x.plist")
  XAPPID=$(/usr/libexec/PlistBuddy -c 'Print Entitlements:application-identifier' "$T/x.plist")
  XBUNDLE_ID="${XAPPID#*.}"
  for v in "$XUUID" "$XBUNDLE_ID"; do echo "::add-mask::$v" >&3; done
  for d in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    cp "$T/x.mobileprovision" "$d/$XUUID.mobileprovision"; done
  rm -f "$T/x.mobileprovision" "$T/x.plist"
  { echo "EXT_PROFILE_UUID=$XUUID"; echo "EXT_BUNDLE_ID=$XBUNDLE_ID"; } >> "$GITHUB_ENV"
fi
echo "✔ ok" >&3
