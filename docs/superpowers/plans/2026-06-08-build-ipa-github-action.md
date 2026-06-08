# Build IPA GitHub Action Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Actions workflow that performs a full Reynard iOS build and uploads generated `.ipa` and `.tipa` artifacts.

**Architecture:** Keep the existing repository scripts as the build entry points. Add a CI-only ad-hoc signing switch so macOS runners can archive without Apple certificate secrets, then package the outputs through `tools/release/create-ipa.sh`.

**Tech Stack:** GitHub Actions, macOS hosted runners, Xcode command line tools, shell scripts, Rust/Cargo, Homebrew `ldid`.

---

### Task 1: Add CI Ad-Hoc Signing Support

**Files:**
- Modify: `tools/release/build-app.sh`
- Modify: `browser/Scripts/AddGecko.sh`

- [ ] **Step 1: Run a failing check for the CI signing switch**

Run:

```powershell
if (-not (Select-String -Path 'tools/release/build-app.sh' -Pattern 'REYNARD_AD_HOC_SIGNING' -Quiet)) { throw 'Missing REYNARD_AD_HOC_SIGNING support in build-app.sh' }
if (-not (Select-String -Path 'browser/Scripts/AddGecko.sh' -Pattern 'REYNARD_AD_HOC_SIGNING' -Quiet)) { throw 'Missing REYNARD_AD_HOC_SIGNING support in AddGecko.sh' }
```

Expected: FAIL with `Missing REYNARD_AD_HOC_SIGNING support in build-app.sh`.

- [ ] **Step 2: Update `tools/release/build-app.sh` to pass CI-only Xcode signing overrides**

Replace the final `xcodebuild archive ...` command with:

```sh
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
```

- [ ] **Step 3: Update `browser/Scripts/AddGecko.sh` to ad-hoc sign Gecko files in CI**

Replace:

```sh
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY_NAME:-Apple Development}}"
```

with:

```sh
if [ "${REYNARD_AD_HOC_SIGNING:-0}" = "1" ]; then
	SIGN_IDENTITY="-"
else
	SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY_NAME:-Apple Development}}"
fi
```

- [ ] **Step 4: Run the signing switch check again**

Run:

```powershell
if (-not (Select-String -Path 'tools/release/build-app.sh' -Pattern 'REYNARD_AD_HOC_SIGNING' -Quiet)) { throw 'Missing REYNARD_AD_HOC_SIGNING support in build-app.sh' }
if (-not (Select-String -Path 'browser/Scripts/AddGecko.sh' -Pattern 'REYNARD_AD_HOC_SIGNING' -Quiet)) { throw 'Missing REYNARD_AD_HOC_SIGNING support in AddGecko.sh' }
Write-Host 'CI signing switch is present'
```

Expected: PASS with `CI signing switch is present`.

### Task 2: Ensure TrollStore Package Signs OpenIn Extension

**Files:**
- Modify: `tools/release/create-ipa.sh`

- [ ] **Step 1: Run a failing check for OpenIn ldid signing**

Run:

```powershell
if (-not (Select-String -Path 'tools/release/create-ipa.sh' -Pattern 'OpenIn.appex/OpenIn' -Quiet)) { throw 'Missing OpenIn extension ldid signing' }
```

Expected: FAIL with `Missing OpenIn extension ldid signing`.

- [ ] **Step 2: Add OpenIn extension signing before creating the TrollStore package**

Insert this line after the existing `ldid` command for `Reynard Helper`:

```sh
ldid -S "Payload/Reynard.app/PlugIns/OpenIn.appex/OpenIn"
```

- [ ] **Step 3: Run the OpenIn signing check again**

Run:

```powershell
if (-not (Select-String -Path 'tools/release/create-ipa.sh' -Pattern 'OpenIn.appex/OpenIn' -Quiet)) { throw 'Missing OpenIn extension ldid signing' }
Write-Host 'OpenIn extension ldid signing is present'
```

Expected: PASS with `OpenIn extension ldid signing is present`.

### Task 3: Add the GitHub Actions Workflow

**Files:**
- Create: `.github/workflows/build_ipa.yml`

- [ ] **Step 1: Run a failing check for the workflow file**

Run:

```powershell
if (-not (Test-Path -LiteralPath '.github/workflows/build_ipa.yml')) { throw 'Missing build_ipa workflow' }
```

Expected: FAIL with `Missing build_ipa workflow`.

- [ ] **Step 2: Create `.github/workflows/build_ipa.yml`**

Use this exact content:

```yaml
name: Build IPA

on:
  workflow_dispatch:
  push:
    tags:
      - "v*"

permissions:
  contents: read

concurrency:
  group: build-ipa-${{ github.ref }}
  cancel-in-progress: false

jobs:
  build-ipa:
    name: Build IPA
    runs-on: macos-latest
    timeout-minutes: 360

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          submodules: recursive
          fetch-depth: 0

      - name: Show tool versions
        run: |
          xcodebuild -version
          xcrun --sdk iphoneos --show-sdk-path
          python3 --version
          rustup --version
          cargo --version

      - name: Install dependencies
        run: |
          brew update
          brew install ldid
          rustup target add aarch64-apple-ios

      - name: Update Gecko source
        run: zsh tools/development/update-gecko.sh

      - name: Apply Gecko patches
        run: zsh tools/development/apply-patches.sh

      - name: Build idevice FFI
        run: zsh tools/development/build-idevice.sh

      - name: Build Gecko
        run: sh tools/development/build-gecko.sh

      - name: Archive Reynard
        env:
          REYNARD_AD_HOC_SIGNING: "1"
        run: sh tools/release/build-app.sh

      - name: Create IPA artifacts
        run: sh tools/release/create-ipa.sh

      - name: Upload IPA artifacts
        uses: actions/upload-artifact@v4
        with:
          name: reynard-ipa-${{ github.run_number }}
          path: |
            dist/*.ipa
            dist/*.tipa
          if-no-files-found: error
          retention-days: 14
```

- [ ] **Step 3: Parse the workflow YAML**

Run:

```powershell
python -m pip install --quiet pyyaml
@'
from pathlib import Path
import yaml

path = Path(".github/workflows/build_ipa.yml")
data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
assert data["name"] == "Build IPA"
assert "workflow_dispatch" in data["on"]
assert data["on"]["push"]["tags"] == ["v*"]
assert data["jobs"]["build-ipa"]["runs-on"] == "macos-latest"
steps = data["jobs"]["build-ipa"]["steps"]
assert any(step.get("run") == "zsh tools/development/update-gecko.sh" for step in steps)
assert any(step.get("run") == "zsh tools/development/apply-patches.sh" for step in steps)
assert any(step.get("run") == "zsh tools/development/build-idevice.sh" for step in steps)
assert any(step.get("run") == "sh tools/development/build-gecko.sh" for step in steps)
assert any(step.get("run") == "sh tools/release/build-app.sh" for step in steps)
assert any(step.get("run") == "sh tools/release/create-ipa.sh" for step in steps)
print("workflow yaml is structurally valid")
'@ | python -
```

Expected: PASS with `workflow yaml is structurally valid`.

### Task 4: Final Verification and Commit

**Files:**
- Verify: `.github/workflows/build_ipa.yml`
- Verify: `tools/release/build-app.sh`
- Verify: `browser/Scripts/AddGecko.sh`
- Verify: `tools/release/create-ipa.sh`

- [ ] **Step 1: Verify referenced scripts exist**

Run:

```powershell
$paths = @(
  'tools/development/update-gecko.sh',
  'tools/development/apply-patches.sh',
  'tools/development/build-idevice.sh',
  'tools/development/build-gecko.sh',
  'tools/release/build-app.sh',
  'tools/release/create-ipa.sh'
)
foreach ($path in $paths) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing referenced script: $path"
  }
}
Write-Host 'All referenced scripts exist'
```

Expected: PASS with `All referenced scripts exist`.

- [ ] **Step 2: Check the diff for whitespace errors**

Run:

```powershell
git diff --check
```

Expected: PASS with no output.

- [ ] **Step 3: Review the staged implementation diff**

Run:

```powershell
git diff -- .github/workflows/build_ipa.yml tools/release/build-app.sh browser/Scripts/AddGecko.sh tools/release/create-ipa.sh
```

Expected: Diff only contains the CI signing switch, OpenIn ldid signing, and the new workflow.

- [ ] **Step 4: Commit the implementation**

Run:

```powershell
git add -- .github/workflows/build_ipa.yml tools/release/build-app.sh browser/Scripts/AddGecko.sh tools/release/create-ipa.sh docs/superpowers/plans/2026-06-08-build-ipa-github-action.md
git commit -m "Add IPA build workflow"
```

Expected: Commit succeeds.
