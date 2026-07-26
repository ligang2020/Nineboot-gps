#!/usr/bin/env bash
# Build a device Release app without signing and wrap it as an unsigned IPA.
# This script is deliberately used by both local builds and GitHub Actions so
# the downloadable artifact has exactly the same layout in both places.
set -euo pipefail

PROJECT="mini-ninebot.xcodeproj"
SCHEME="mini-ninebot"
CONFIGURATION="Release"
OUTPUT_DIR="${PWD}/build/ipa"
DERIVED_DATA="${PWD}/build/DerivedData"

usage() {
  cat <<'USAGE'
Usage: scripts/package-unsigned-ipa.sh [--output <directory>] [--derived-data <directory>]

Builds the mini-ninebot iPhoneOS Release app with signing disabled, packages a
versioned unsigned IPA, and prints the final IPA path on stdout.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$OUTPUT_DIR" "$DERIVED_DATA"
# The archive step runs from a temporary directory. Normalize caller-supplied
# relative paths first so the IPA is always written to the requested location.
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -sdk iphoneos \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build >&2

APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
INFO_PLIST="$APP_PATH/Info.plist"

test -d "$APP_PATH"
test -d "$APP_PATH/PlugIns/NinebotWidgets.appex"
test -f "$APP_PATH/Assets.car"
plutil -lint "$INFO_PLIST" >&2
/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$INFO_PLIST" | grep -qx 'AppIcon'

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
IPA_BASENAME="NinePlus-LiveRide-v${VERSION}-unsigned.ipa"
IPA_PATH="$OUTPUT_DIR/$IPA_BASENAME"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nineplus-ipa.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/Payload"
ditto "$APP_PATH" "$WORK_DIR/Payload/${SCHEME}.app"
(
  cd "$WORK_DIR"
  /usr/bin/zip -qry "$IPA_PATH" Payload
)
# Store only the IPA basename in the checksum file. This makes the checksum
# valid after GitHub Actions uploads it and a user downloads it elsewhere.
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$(basename "$IPA_PATH")" > "$(basename "$IPA_PATH").sha256"
)
printf '%s\n' "$IPA_PATH"
