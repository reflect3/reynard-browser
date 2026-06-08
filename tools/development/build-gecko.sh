#!/bin/sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
FIREFOX_DIR="$ROOT_DIR/engine/firefox"

TARGET="aarch64-apple-ios"

cd "$ROOT_DIR"

if command -v brew >/dev/null 2>&1; then
	if LLVM_PREFIX="$(brew --prefix llvm 2>/dev/null)" && [ -d "$LLVM_PREFIX/bin" ]; then
		PATH="$LLVM_PREFIX/bin:$PATH"
		export PATH
	fi
fi

if [ ! -d "$FIREFOX_DIR" ]; then
	echo "Missing firefox source at $FIREFOX_DIR"
	echo "Add the submodule, then run tools/development/update-gecko.sh."
	exit 1
fi

rm -f "$FIREFOX_DIR/.mozconfig"

{
	echo "ac_add_options --enable-application=mobile/ios"
	echo "ac_add_options --target=$TARGET"
	echo "ac_add_options --enable-ios-target=13.0"
	echo "ac_add_options --enable-webrtc"
	echo "ac_add_options --enable-optimize"
	echo "ac_add_options --enable-linker=lld"
	echo "ac_add_options --disable-debug"
	echo "ac_add_options --disable-tests"
} > "$FIREFOX_DIR/.mozconfig"

if ! rustup target list | grep -q "^$TARGET (installed)"; then
	rustup target add "$TARGET"
fi

cd "$FIREFOX_DIR"
./mach build
