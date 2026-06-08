#!/bin/sh

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
FIREFOX_DIR="$ROOT_DIR/engine/firefox"

TARGET="aarch64-apple-ios"
IOS_TARGET="13.0"

cd "$ROOT_DIR"

if command -v brew >/dev/null 2>&1; then
	if LLVM_PREFIX="$(brew --prefix llvm 2>/dev/null)" && [ -d "$LLVM_PREFIX/bin" ]; then
		PATH="$LLVM_PREFIX/bin:$PATH"
		export PATH
	fi
fi

detect_lld_linker() {
	if ! command -v ld64.lld >/dev/null 2>&1 && ! command -v lld >/dev/null 2>&1; then
		return 1
	fi

	if ! command -v clang >/dev/null 2>&1; then
		return 1
	fi

	LINKER_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reynard-lld.XXXXXX")" || return 1
	LINKER_TEST_RESULT=1

	if printf 'int main(void) { return 0; }\n' > "$LINKER_TEST_DIR/test.c"; then
		IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"

		if [ -n "$IPHONEOS_SDK" ]; then
			if clang --target="$TARGET" -isysroot "$IPHONEOS_SDK" -mios-version-min="$IOS_TARGET" -fuse-ld=lld "$LINKER_TEST_DIR/test.c" -o "$LINKER_TEST_DIR/test" >/dev/null 2>&1; then
				LINKER_TEST_RESULT=0
			fi
		elif clang --target="$TARGET" -mios-version-min="$IOS_TARGET" -fuse-ld=lld "$LINKER_TEST_DIR/test.c" -o "$LINKER_TEST_DIR/test" >/dev/null 2>&1; then
			LINKER_TEST_RESULT=0
		fi
	fi

	rm -rf "$LINKER_TEST_DIR"
	return "$LINKER_TEST_RESULT"
}

if [ ! -d "$FIREFOX_DIR" ]; then
	echo "Missing firefox source at $FIREFOX_DIR"
	echo "Add the submodule, then run tools/development/update-gecko.sh."
	exit 1
fi

GECKO_LINKER_OPTION=""
if detect_lld_linker; then
	GECKO_LINKER_OPTION="--enable-linker=lld"
else
	echo "Homebrew LLVM lld was not found or failed the clang preflight; Gecko will use its default linker." >&2
fi

rm -f "$FIREFOX_DIR/.mozconfig"

{
	echo "ac_add_options --enable-application=mobile/ios"
	echo "ac_add_options --target=$TARGET"
	echo "ac_add_options --enable-ios-target=$IOS_TARGET"
	echo "ac_add_options --enable-webrtc"
	echo "ac_add_options --enable-optimize"
	echo "ac_add_options --without-wasm-sandboxed-libraries"
	if [ -n "$GECKO_LINKER_OPTION" ]; then
		echo "ac_add_options $GECKO_LINKER_OPTION"
	fi
	echo "ac_add_options --disable-debug"
	echo "ac_add_options --disable-tests"
} > "$FIREFOX_DIR/.mozconfig"

if ! rustup target list | grep -q "^$TARGET (installed)"; then
	rustup target add "$TARGET"
fi

cd "$FIREFOX_DIR"
./mach build
