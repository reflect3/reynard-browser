# Fix Tab Restore About Blank Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the last real tab URL after app relaunch and prevent Gecko's initial `about:blank` location event from overwriting the tab snapshot or address bar.

**Architecture:** Keep the fix inside `TabManagerImplementation`, which already owns restored tab creation, location-change handling, and persistence. During restore, resolve the effective URL from the tab snapshot first and `TabSessionStore.currentURL` second, then keep `suppressInitialNavigation` active until the first non-blank location change arrives.

**Tech Stack:** Swift, UIKit, custom Reynard GeckoView wrapper, `TabManagementStore` SQLite tab snapshots, `TabSessionStore` JSON navigation snapshots, Xcode iOS build tooling.

---

### Task 1: Add Session Store Fallback For Restored URLs

**Files:**
- Modify: `browser/Reynard/Client/TabManagement/TabManagerImpl.swift:212-220`
- Modify: `browser/Reynard/Client/TabManagement/TabManagerImpl.swift:304-341`

- [ ] **Step 1: Run the failing fallback check**

Run:

```powershell
if (-not (Select-String -Path 'browser/Reynard/Client/TabManagement/TabManagerImpl.swift' -Pattern 'fallback: sessionSnapshot.currentURL' -Quiet)) { throw 'Missing TabSessionStore currentURL fallback during tab restore' }
```

Expected: FAIL with `Missing TabSessionStore currentURL fallback during tab restore`.

- [ ] **Step 2: Add a two-source restored URL helper**

In `browser/Reynard/Client/TabManagement/TabManagerImpl.swift`, immediately after the existing `private func restoredURL(from value: String?) -> String?` method, add:

```swift
    private func restoredURL(from value: String?, fallback fallbackValue: String?) -> String? {
        restoredURL(from: value) ?? restoredURL(from: fallbackValue)
    }
```

- [ ] **Step 3: Update regular tab restoration to use the fallback URL**

In `restoreTabsIfNeeded()`, replace the `regularTabs = snapshot.regularTabs.map { snapshot in ... }` block with:

```swift
        regularTabs = snapshot.regularTabs.map { snapshot in
            let sessionSnapshot = sessionStore.loadSnapshot(for: snapshot.id)
            let restoreURL = restoredURL(from: snapshot.url, fallback: sessionSnapshot.currentURL)
            let displayURL = restoreURL ?? snapshot.url
            let tab = Tab(
                id: snapshot.id,
                session: createSession(windowId: nil, isPrivate: false),
                title: snapshot.title,
                url: displayURL,
                favicon: cachedFavicon(for: displayURL),
                thumbnail: snapshot.thumbnail,
                isPrivate: false
            )
            tab.pendingRestoreURL = restoreURL
            if sessionSnapshot.canGoBack || sessionSnapshot.canGoForward {
                _ = sessionStore.setOwnsNav(true, for: tab.id)
            }
            applyNavigationState(to: tab)
            let controller = NowPlayingController(session: tab.session)
            tab.session.mediaSessionDelegate = controller
            tab.nowPlayingController = controller
            return tab
        }
```

- [ ] **Step 4: Update private tab restoration to use the same fallback URL**

In `restoreTabsIfNeeded()`, replace the `privateTabs = snapshot.privateTabs.map { snapshot in ... }` block with:

```swift
        privateTabs = snapshot.privateTabs.map { snapshot in
            let sessionSnapshot = sessionStore.loadSnapshot(for: snapshot.id)
            let restoreURL = restoredURL(from: snapshot.url, fallback: sessionSnapshot.currentURL)
            let displayURL = restoreURL ?? snapshot.url
            let tab = Tab(
                id: snapshot.id,
                session: createSession(windowId: nil, isPrivate: true),
                title: snapshot.title,
                url: displayURL,
                favicon: cachedFavicon(for: displayURL),
                thumbnail: snapshot.thumbnail,
                isPrivate: true
            )
            tab.pendingRestoreURL = restoreURL
            if sessionSnapshot.canGoBack || sessionSnapshot.canGoForward {
                _ = sessionStore.setOwnsNav(true, for: tab.id)
            }
            applyNavigationState(to: tab)
            let controller = NowPlayingController(session: tab.session)
            tab.session.mediaSessionDelegate = controller
            tab.nowPlayingController = controller
            return tab
        }
```

- [ ] **Step 5: Run the fallback check again**

Run:

```powershell
if (-not (Select-String -Path 'browser/Reynard/Client/TabManagement/TabManagerImpl.swift' -Pattern 'fallback: sessionSnapshot.currentURL' -Quiet)) { throw 'Missing TabSessionStore currentURL fallback during tab restore' }
$matches = Select-String -Path 'browser/Reynard/Client/TabManagement/TabManagerImpl.swift' -Pattern 'fallback: sessionSnapshot.currentURL'
if ($matches.Count -ne 2) { throw "Expected 2 fallback restore sites, found $($matches.Count)" }
```

Expected: PASS with no output.

- [ ] **Step 6: Commit**

Run:

```powershell
git add browser/Reynard/Client/TabManagement/TabManagerImpl.swift
git commit -m "fix: recover restored tab url from session store"
```

Expected: commit succeeds.

### Task 2: Preserve Initial Blank Suppression During Restored Loads

**Files:**
- Modify: `browser/Reynard/Client/TabManagement/TabManagerImpl.swift:368-380`

- [ ] **Step 1: Run the failing suppression check**

Run:

```powershell
$source = Get-Content -LiteralPath 'browser/Reynard/Client/TabManagement/TabManagerImpl.swift' -Raw
$restoreFunction = [regex]::Match($source, 'private func loadRestoredURLIfNeeded[\s\S]*?func createInitialTab').Value
if ($restoreFunction -match 'suppressInitialNavigation = false') { throw 'Restored load clears initial blank suppression too early' }
```

Expected: FAIL with `Restored load clears initial blank suppression too early`.

- [ ] **Step 2: Keep suppression enabled before loading a restored URL**

In `loadRestoredURLIfNeeded(for:mode:)`, replace:

```swift
        tab.pendingRestoreURL = nil
        tab.suppressInitialNavigation = false
        loadURL(url, in: tab)
```

with:

```swift
        tab.pendingRestoreURL = nil
        tab.suppressInitialNavigation = true
        loadURL(url, in: tab)
```

- [ ] **Step 3: Run the suppression check again**

Run:

```powershell
$source = Get-Content -LiteralPath 'browser/Reynard/Client/TabManagement/TabManagerImpl.swift' -Raw
$restoreFunction = [regex]::Match($source, 'private func loadRestoredURLIfNeeded[\s\S]*?func createInitialTab').Value
if ($restoreFunction -match 'suppressInitialNavigation = false') { throw 'Restored load clears initial blank suppression too early' }
if ($restoreFunction -notmatch 'suppressInitialNavigation = true') { throw 'Restored load does not explicitly preserve initial blank suppression' }
```

Expected: PASS with no output.

- [ ] **Step 4: Verify user-initiated navigation still disables suppression**

Run:

```powershell
$matches = Select-String -Path 'browser/Reynard/Client/TabManagement/TabManagerImpl.swift' -Pattern 'suppressInitialNavigation = false'
$matches | ForEach-Object { $_.LineNumber.ToString() + ': ' + $_.Line.Trim() }
```

Expected: output still includes `tab.suppressInitialNavigation = false` in `browse(to:in:)` and in `onLocationChange` after a non-empty location, but not inside `loadRestoredURLIfNeeded`.

- [ ] **Step 5: Commit**

Run:

```powershell
git add browser/Reynard/Client/TabManagement/TabManagerImpl.swift
git commit -m "fix: ignore initial blank location on restored tabs"
```

Expected: commit succeeds.

### Task 3: Verify Restore Behavior

**Files:**
- Verify: `browser/Reynard/Client/TabManagement/TabManagerImpl.swift`
- Verify: `browser/Reynard/Client/Stores/TabManagementStore.swift`
- Verify: `browser/Reynard/Client/Stores/TabSessionStore.swift`

- [ ] **Step 1: Run static regression checks**

Run:

```powershell
if (Select-String -Path 'browser/Reynard/Client/TabManagement/TabManagerImpl.swift' -Pattern 'tab.pendingRestoreURL = restoredURL\(from: snapshot.url\)' -Quiet) { throw 'Restore still uses only the tab snapshot URL' }

$fallbackMatches = Select-String -Path 'browser/Reynard/Client/TabManagement/TabManagerImpl.swift' -Pattern 'fallback: sessionSnapshot.currentURL'
if ($fallbackMatches.Count -ne 2) { throw "Expected 2 fallback restore sites, found $($fallbackMatches.Count)" }

$source = Get-Content -LiteralPath 'browser/Reynard/Client/TabManagement/TabManagerImpl.swift' -Raw
$restoreFunction = [regex]::Match($source, 'private func loadRestoredURLIfNeeded[\s\S]*?func createInitialTab').Value
if ($restoreFunction -match 'suppressInitialNavigation = false') { throw 'Restored load clears initial blank suppression too early' }
if ($restoreFunction -notmatch 'suppressInitialNavigation = true') { throw 'Restored load does not explicitly preserve initial blank suppression' }
```

Expected: PASS with no output.

- [ ] **Step 2: Build on macOS**

Run this on a macOS machine with Xcode and the iPhoneOS SDK:

```sh
xcodebuild -project browser/Reynard.xcodeproj -scheme Reynard -configuration Debug -destination 'generic/platform=iOS' build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manually verify a clean restored tab**

Use an iOS device or simulator that can run the current Reynard build:

```text
1. Launch Reynard with a clean or non-corrupted app state.
2. Open https://example.com/ in the selected regular tab.
3. Wait until the page finishes loading and the address bar shows https://example.com/.
4. Send the app to the background.
5. Force quit the app.
6. Launch the app again.
```

Expected:

```text
The selected tab reloads https://example.com/.
The address bar shows https://example.com/, not about:blank.
The tab overview card for the selected tab does not change its URL to about:blank during restore.
```

- [ ] **Step 4: Manually verify recovery from an already corrupted tab snapshot**

Use an app state that previously reproduced the reported issue, where `TabManagementStore` contains `about:blank` for the selected tab but `TabSessionStore.currentURL` still contains the real URL:

```text
1. Install the fixed build without clearing app data.
2. Launch Reynard.
3. Select the tab that previously restored to about:blank.
4. Wait for the restored load to start.
```

Expected:

```text
The selected tab uses TabSessionStore.currentURL as the restored URL.
The address bar shows the real URL from the previous session.
After the page emits its real onLocationChange event, TabManagementStore is persisted with that real URL.
```

- [ ] **Step 5: Manually verify a new blank tab still works**

Use the fixed build:

```text
1. Launch Reynard.
2. Create a new blank tab.
3. Type about:blank in the address bar and submit it.
4. Create another new tab and browse to https://example.org/.
```

Expected:

```text
Explicitly browsing to about:blank still displays about:blank.
Browsing to https://example.org/ still updates the address bar and tab snapshot to https://example.org/.
```

- [ ] **Step 6: Commit verification notes if a notes file is used**

If the implementation session records device verification notes, save them under `docs/superpowers/verification/` and commit them:

```powershell
git add docs/superpowers/verification
git commit -m "docs: record tab restore verification"
```

Expected: commit succeeds only when a verification notes file was created; skip this commit when no notes file exists.

### Self-Review

- Spec coverage: Task 1 recovers already polluted snapshots through `TabSessionStore.currentURL`; Task 2 prevents initial Gecko `about:blank` from polluting fresh restored snapshots; Task 3 covers static checks, build verification, clean restore, corrupted restore, and explicit `about:blank` navigation.
- Placeholder scan: The plan contains concrete paths, code snippets, commands, and expected results.
- Type consistency: The helper reuses existing `restoredURL(from:)`, `sessionStore.loadSnapshot(for:)`, `TabSessionStore.Snapshot.currentURL`, `Tab.pendingRestoreURL`, and `Tab.suppressInitialNavigation` names exactly as they exist in the current code.

