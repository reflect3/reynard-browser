# Build IPA GitHub Action Design

## Goal

Add a GitHub Actions workflow that performs a full CI build for Reynard Browser and uploads generated iOS package artifacts.

## Context

Reynard is a native iOS Xcode project under `browser/Reynard.xcodeproj`. The repository already has release scripts:

- `tools/release/build-app.sh` archives the `Reynard` scheme to `dist/Reynard.xcarchive`.
- `tools/release/create-ipa.sh` packages `dist/Reynard.ipa`, `dist/Reynard-TrollStore.tipa`, and `dist/Reynard-Jailbroken.ipa`.

The release scripts depend on generated Gecko outputs at `engine/firefox/obj-aarch64-apple-ios/dist` and on `browser/Reynard/JIT/libidevice_ffi.a`. A full CI build therefore needs to run the existing development scripts before packaging the app.

## Workflow

Create `.github/workflows/build_ipa.yml`.

The workflow should run on `macos-latest`, because Xcode and the iPhoneOS SDK are required. It should support manual execution with `workflow_dispatch` and automatic execution for version tags matching `v*`.

The job should:

1. Check out the repository with submodules.
2. Install build dependencies needed by the existing scripts, including Rust's `aarch64-apple-ios` target and `ldid`.
3. Run `tools/development/update-gecko.sh`.
4. Run `tools/development/apply-patches.sh`.
5. Run `tools/development/build-idevice.sh`.
6. Run `tools/development/build-gecko.sh`.
7. Run `tools/release/build-app.sh`.
8. Run `tools/release/create-ipa.sh`.
9. Upload package artifacts from `dist/*.ipa` and `dist/*.tipa`.

## Signing Scope

The workflow will use the repository's existing build and packaging scripts. It will not introduce Apple certificate or provisioning profile secrets in this change.

This keeps the first CI version focused on reproducing the current sideload, TrollStore, and jailbroken packaging flow. App Store, TestFlight, or formally provisioned builds can be added later with explicit certificate and profile handling.

## Error Handling

The workflow should fail fast if any existing script fails. Each major phase should be a separate named step so GitHub Actions logs make it clear whether the failure came from source sync, patching, Gecko build, app archive, or IPA packaging.

## Verification

Local verification on Windows cannot execute the macOS-only build. The implementation should instead verify:

- workflow YAML parses structurally,
- referenced repository scripts and artifact paths exist,
- the shell commands match the existing script entry points.
