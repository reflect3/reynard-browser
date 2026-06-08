#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
PROJECT_PATH="$ROOT_DIR/browser/Reynard.xcodeproj"
XCCONFIG_PATH="$ROOT_DIR/browser/Configuration/Reynard.xcconfig"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

cp "$XCCONFIG_PATH" "$DIST_DIR/Reynard.xcconfig"

BUILD_SHA=$(git -C "$ROOT_DIR" rev-parse --short HEAD)
sed -i '' "s/CURRENT_BUILD = .*/CURRENT_BUILD = $BUILD_SHA/" "$DIST_DIR/Reynard.xcconfig"

set -- archive \
	-scheme "Reynard" \
	-archivePath "$DIST_DIR/Reynard.xcarchive" \
	-project "$PROJECT_PATH" \
	-sdk iphoneos \
	-arch arm64 \
	-configuration Release \
	-xcconfig "$DIST_DIR/Reynard.xcconfig"

if [ "${REYNARD_AD_HOC_SIGNING:-0}" = "1" ]; then
	set -- "$@" \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY=- \
		DEVELOPMENT_TEAM= \
		PROVISIONING_PROFILE_SPECIFIER=
fi

xcodebuild "$@"
