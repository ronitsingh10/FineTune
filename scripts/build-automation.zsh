#!/bin/zsh
set -euo pipefail
# Build locally without changing the stock application or publishing a release.
task_root=${0:A:h:h}
task_derived=${FINETUNE_DERIVED_DATA:-${TMPDIR:-/private/tmp}/finetune-automation-release}
task_destination=${1:-$task_root/dist}
mkdir -p "$task_destination"
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcodebuild build \
  -project "$task_root/FineTune.xcodeproj" -scheme FineTune -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$task_derived" \
  PRODUCT_BUNDLE_IDENTIFIER=com.finetuneapp.FineTune.Automation \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=FINETUNE_CUSTOM_BUILD CODE_SIGNING_ALLOWED=NO

task_assembly="$task_derived/AutomationDistribution"
mkdir -p "$task_assembly"
task_bundle="$task_assembly/FineTune Automation.app"
ditto "$task_derived/Build/Products/Release/FineTune.app" "$task_bundle"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName FineTune Automation' "$task_bundle/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string FineTune Automation' "$task_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName FineTune Automation' "$task_bundle/Contents/Info.plist"
xattr -cr "$task_bundle"
codesign --force --deep --sign - --entitlements "$task_root/FineTune/FineTune.entitlements" "$task_bundle"
codesign --verify --deep --strict "$task_bundle"
ditto -c -k --sequesterRsrc --keepParent "$task_bundle" "$task_assembly/FineTune-Automation-macOS.zip"
cp "$task_assembly/FineTune-Automation-macOS.zip" "$task_destination/FineTune-Automation-macOS.zip"
