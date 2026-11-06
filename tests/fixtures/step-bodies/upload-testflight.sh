exec 3>&1 >>"$LOG" 2>&1; set -E; trap 'echo "✖ failed" >&3' ERR
umask 077; D="$HOME/.appstoreconnect/private_keys"; mkdir -p "$D"
printf '%s' "$ASC_KEY_P8_B64" | base64 --decode > "$D/AuthKey_${ASC_KEY_ID}.p8"
IPA=$(ls "$RUNNER_TEMP"/export/*.ipa | head -1)
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format normal
echo "✔ ok" >&3
