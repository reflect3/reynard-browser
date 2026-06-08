$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

$BuildGeckoPath = Join-Path $RepoRoot "tools/development/build-gecko.sh"
$WorkflowPath = Join-Path $RepoRoot ".github/workflows/build_ipa.yml"
$ReadmePath = Join-Path $RepoRoot "README.md"
$GeckoToolchainPatchPath = Join-Path $RepoRoot "patches/build/moz.configure/toolchain.configure.patch"

$BuildGecko = Get-Content -Raw -LiteralPath $BuildGeckoPath
$Workflow = Get-Content -Raw -LiteralPath $WorkflowPath
$Readme = Get-Content -Raw -LiteralPath $ReadmePath

if (-not (Test-Path -LiteralPath $GeckoToolchainPatchPath)) {
	throw "Gecko toolchain.configure linker workaround patch is missing."
}

$GeckoToolchainPatch = Get-Content -Raw -LiteralPath $GeckoToolchainPatchPath

function Assert-Matches {
	param(
		[string] $Text,
		[string] $Pattern,
		[string] $Message
	)

	if ($Text -notmatch $Pattern) {
		throw $Message
	}
}

function Assert-DoesNotMatch {
	param(
		[string] $Text,
		[string] $Pattern,
		[string] $Message
	)

	if ($Text -match $Pattern) {
		throw $Message
	}
}

Assert-Matches $BuildGecko '(?m)^detect_lld_linker\(\) \{' "build-gecko.sh must detect lld before enabling it."
Assert-Matches $BuildGecko 'command -v ld64\.lld' "build-gecko.sh must check for Darwin ld64.lld."
Assert-Matches $BuildGecko 'command -v lld' "build-gecko.sh must check for lld."
Assert-Matches $BuildGecko '-fuse-ld=lld' "build-gecko.sh must preflight clang with -fuse-ld=lld."
Assert-Matches $BuildGecko 'GECKO_LINKER_OPTION' "build-gecko.sh must write linker mozconfig through a detected option."
Assert-Matches $BuildGecko '--without-wasm-sandboxed-libraries' "build-gecko.sh must disable wasm sandboxed libraries to avoid requiring a WASI sysroot."
Assert-DoesNotMatch $BuildGecko '(?m)^\s*echo "ac_add_options --enable-linker=lld"\s*$' "build-gecko.sh must not unconditionally write --enable-linker=lld."

Assert-Matches $GeckoToolchainPatch 'diff --git a/build/moz\.configure/toolchain\.configure b/build/moz\.configure/toolchain\.configure' "Gecko linker workaround patch must target toolchain.configure."
Assert-Matches $GeckoToolchainPatch '-Wl,--version' "Gecko linker workaround patch must document the original GNU-style linker version probe."
Assert-Matches $GeckoToolchainPatch '-Wl,-ld_classic,-v' "Gecko linker workaround patch must use the Apple-compatible ld_classic version probe."
Assert-Matches $GeckoToolchainPatch '1844694' "Gecko linker workaround patch must reference Mozilla bug 1844694."

Assert-DoesNotMatch $Workflow 'GITHUB_PATH' "build_ipa.yml must not add Homebrew LLVM to the global GitHub Actions PATH."
Assert-Matches $Workflow 'brew install llvm ldid cbindgen' "build_ipa.yml must install cbindgen for Gecko builds."
Assert-Matches $Workflow 'cbindgen --version' "build_ipa.yml must show the cbindgen version for diagnostics."

Assert-Matches $Readme '(?i)LLVM' "README.md must document the LLVM dependency for Gecko builds."
Assert-Matches $Readme '(?i)lld' "README.md must document the lld linker dependency for Gecko builds."
Assert-Matches $Readme '(?i)cbindgen' "README.md must document the cbindgen dependency for Gecko builds."

Write-Host "build configuration tests passed"
