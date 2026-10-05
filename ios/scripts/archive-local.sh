#!/bin/bash
# Local-only archive/export. Requires Xcode, XcodeGen, Python 3.9+, an installed
# GNAB App Store profile, and its distribution identity in the local keychain.
# Export GNAB_TEAM_ID, GNAB_PROFILE_PATH (outside Git), GNAB_BUILD_NUMBER, then run:
# bash ios/scripts/archive-local.sh
# The resulting IPA can be reviewed and uploaded through Apple's Transporter.
set -euo pipefail
if [[ "$(uname -s)" != Darwin || -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "Use an approved local Mac. This script never signs in CI." >&2
  exit 1
fi
: "${GNAB_TEAM_ID:?Set the GNAB Apple team ID}"
: "${GNAB_PROFILE_PATH:?Set the local GNAB App Store provisioning profile path}"
: "${GNAB_BUILD_NUMBER:?Set a new positive build number}"
export GNAB_TEAM_ID GNAB_PROFILE_PATH GNAB_BUILD_NUMBER
[[ "$GNAB_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid build number" >&2; exit 1; }
for tool in xcodebuild xcodegen python3 security codesign; do
  command -v "$tool" >/dev/null || { echo "Missing local tool: $tool" >&2; exit 1; }
done
cd "$(dirname "$0")/.."
mkdir -p build/local-release
release_dir=$(mktemp -d "$PWD/build/local-release/build-$GNAB_BUILD_NUMBER-XXXXXX")
python3 scripts/local_signing.py "$release_dir/ExportOptions.plist" "$release_dir/signing-identifiers.txt"
profile_uuid=$(sed -n '1p' "$release_dir/signing-identifiers.txt")
certificate=$(sed -n '2p' "$release_dir/signing-identifiers.txt")
xcodegen generate
xcodebuild archive -project NabcamIOS.xcodeproj -scheme NabcamIOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$release_dir/GnabCam.xcarchive" \
  DEVELOPMENT_TEAM="$GNAB_TEAM_ID" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$certificate" PROVISIONING_PROFILE_SPECIFIER="$profile_uuid" \
  CURRENT_PROJECT_VERSION="$GNAB_BUILD_NUMBER"
app="$release_dir/GnabCam.xcarchive/Products/Applications/NabcamIOS.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")" == com.gnabcamirl.app ]]
codesign --verify --deep --strict "$app"
xcodebuild -exportArchive -archivePath "$release_dir/GnabCam.xcarchive" \
  -exportPath "$release_dir/export" -exportOptionsPlist "$release_dir/ExportOptions.plist"
echo "Local export finished: $release_dir/export"
echo "Nothing was uploaded. Review the IPA before uploading with Transporter."
