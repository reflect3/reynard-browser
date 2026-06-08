//
//  TabManagerImpl.swift
//  Reynard
//
//  Created by Minh Ton on 5/3/26.
//

import Foundation
import GeckoView
import UIKit

private enum PendingHistoryDirection {
    case back
    case forward
}

private final class PendingHistoryNavigation {
    let direction: PendingHistoryDirection
    let token: UUID
    let startedURL: String?
    let expectedURL: String?
    weak var session: GeckoSession?
    var fallbackTask: Task<Void, Never>?
    
    init(direction: PendingHistoryDirection, token: UUID, startedURL: String?, expectedURL: String?, session: GeckoSession) {
        self.direction = direction
        self.token = token
        self.startedURL = startedURL
        self.expectedURL = expectedURL
        self.session = session
    }
}

final class TabManagerImplementation: NSObject, TabManager {
    private static let pendingHistoryFallbackDelayNanoseconds: UInt64 = 900_000_000
    
    private(set) var regularTabs: [Tab] = []
    private(set) var privateTabs: [Tab] = []
    private(set) var selectedTabMode: TabMode = .regular
    private var selectedRegularTabIndex = -1
    private var selectedPrivateTabIndex = -1
    
    var selectedTabIndex: Int {
        selectedIndex(for: selectedTabMode)
    }
    
    var selectedTab: Tab? {
        tabs(for: selectedTabMode)[safe: selectedTabIndex]
    }
    
    private weak var delegate: TabManagerDelegate?
    private let store: TabManagementStore
    private let faviconStore: FaviconStore
    private let historyStore: HistoryStore
    private let sessionStore: TabSessionStore
    private var faviconTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingHistoryNavigations: [UUID: PendingHistoryNavigation] = [:]
    private var pendingObservedNavigationIntents: [UUID: TabSessionStore.ObservedNavigationIntent] = [:]
    private var replaceNavigationTabIDs: Set<UUID> = []
    private var selectionCounter = 0
    
    private lazy var isURLLenient: NSRegularExpression = {
        let pattern = "^\\s*(\\w+-+)*[\\w\\[]+(://[/]*|:|\\.)(\\w+-+)*[\\w\\[:]+([\\S&&[^\\w-]]\\S*)?\\s*$"
        return try! NSRegularExpression(pattern: pattern)
    }()
    
    init(
        delegate: TabManagerDelegate?,
        store: TabManagementStore = .shared,
        sessionStore: TabSessionStore = .shared,
        faviconStore: FaviconStore = .shared,
        historyStore: HistoryStore = .shared
    ) {
        self.delegate = delegate
        self.store = store
        self.sessionStore = sessionStore
        self.faviconStore = faviconStore
        self.historyStore = historyStore
    }
    
    private func closeSession(_ session: GeckoSession) {
        SitePermissionStore.shared.removePrivateTabPerms(for: session)
        if session.isOpen() {
            session.setActive(false)
        }
        session.close()
    }
    
    private func cancelFaviconTask(for tabID: UUID) {
        faviconTasks.removeValue(forKey: tabID)?.cancel()
    }
    
    private func persistState() {
        store.saveTabs(
            regularTabs: regularTabs,
            privateTabs: privateTabs,
            selectedRegularTabID: regularTabs[safe: selectedRegularTabIndex]?.id,
            selectedPrivateTabID: privateTabs[safe: selectedPrivateTabIndex]?.id,
            selectedTabMode: selectedTabMode
        )
    }
    
    private func tabs(for mode: TabMode) -> [Tab] {
        switch mode {
        case .regular:
            return regularTabs
        case .private:
            return privateTabs
        }
    }
    
    private func selectedIndex(for mode: TabMode) -> Int {
        switch mode {
        case .regular:
            return selectedRegularTabIndex
        case .private:
            return selectedPrivateTabIndex
        }
    }
    
    private func setSelectedIndex(_ index: Int, for mode: TabMode) {
        switch mode {
        case .regular:
            selectedRegularTabIndex = index
        case .private:
            selectedPrivateTabIndex = index
        }
    }
    
    private func tabLocation(for session: GeckoSession) -> (mode: TabMode, index: Int)? {
        if let index = regularTabs.firstIndex(where: { $0.session === session }) {
            return (.regular, index)
        }
        
        if let index = privateTabs.firstIndex(where: { $0.session === session }) {
            return (.private, index)
        }
        
        return nil
    }
    
    private func tabLocation(for tabID: UUID) -> (mode: TabMode, index: Int)? {
        if let index = regularTabs.firstIndex(where: { $0.id == tabID }) {
            return (.regular, index)
        }
        
        if let index = privateTabs.firstIndex(where: { $0.id == tabID }) {
            return (.private, index)
        }
        
        return nil
    }
    
    private func notifyUpdate(at index: Int, mode: TabMode, reason: TabManagerUpdateReason) {
        if mode == selectedTabMode {
            delegate?.tabManager(self, didUpdateTabAt: index, reason: reason)
        } else {
            delegate?.tabManagerDidChangeTabs(self)
        }
    }
    
    private func loadURL(_ url: String, in tab: Tab) {
        tab.session.updateSettings(GeckoSessionController.shared.sessionSettings(for: url, tabID: tab.id))
        tab.session.load(url)
    }
    
    private func loadHistoryURL(_ url: String, in tab: Tab) {
        replaceNavigationTabIDs.insert(tab.id)
        pendingObservedNavigationIntents[tab.id] = .replace
        tab.session.updateSettings(GeckoSessionController.shared.sessionSettings(for: url, tabID: tab.id))
        tab.session.load(url, flags: GeckoSessionLoadFlags.replaceHistory)
    }
    
    private func applyNavigationState(to tab: Tab, from snapshot: TabSessionStore.Snapshot) {
        if snapshot.ownsNav {
            tab.canNavigateBack = snapshot.canGoBack
            tab.canNavigateForward = snapshot.canGoForward
            return
        }
        
        tab.canNavigateBack = snapshot.canGoBack || tab.sessionCanGoBack
        tab.canNavigateForward = snapshot.canGoForward || tab.sessionCanGoForward
    }
    
    private func applyNavigationState(to tab: Tab) {
        let snapshot = sessionStore.loadSnapshot(for: tab.id)
        applyNavigationState(to: tab, from: snapshot)
    }
    
    private func recordNavigation(
        _ url: String,
        for tab: Tab,
        intent: TabSessionStore.ObservedNavigationIntent? = .normal
    ) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              trimmedURL.lowercased() != "about:blank" else {
            return
        }
        
        let snapshot = sessionStore.recordObservedNavigation(to: trimmedURL, for: tab.id, intent: intent)
        applyNavigationState(to: tab, from: snapshot)
    }
    
    private func observedIntent(for direction: PendingHistoryDirection) -> TabSessionStore.ObservedNavigationIntent {
        switch direction {
        case .back:
            return .back
        case .forward:
            return .forward
        }
    }
    
    private func normalizedNavigationURL(_ value: String?) -> String? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty else {
            return nil
        }
        
        return trimmedValue
    }
    
    private func shouldWaitForMeaningfulHistoryChange(_ pending: PendingHistoryNavigation, observedURL: String) -> Bool {
        let observedURL = normalizedNavigationURL(observedURL)
        let startedURL = normalizedNavigationURL(pending.startedURL)
        guard observedURL == startedURL else {
            return false
        }

        guard let expectedURL = normalizedNavigationURL(pending.expectedURL) else {
            return true
        }
        return expectedURL != startedURL
    }

    private func clearPendingHistoryNavigation(for tabID: UUID, token: UUID? = nil) {
        guard let pending = pendingHistoryNavigations[tabID] else {
            return
        }
        
        if let token,
           pending.token != token {
            return
        }
        
        pending.fallbackTask?.cancel()
        pendingHistoryNavigations.removeValue(forKey: tabID)
    }
    
    private func clearPendingNavigationState(for tabID: UUID) {
        clearPendingHistoryNavigation(for: tabID)
        pendingObservedNavigationIntents.removeValue(forKey: tabID)
        replaceNavigationTabIDs.remove(tabID)
    }
    
    private func startPendingHistoryNavigation(
        for tab: Tab,
        direction: PendingHistoryDirection,
        expectedURL: String?
    ) {
        clearPendingNavigationState(for: tab.id)
        let token = UUID()
        let pending = PendingHistoryNavigation(
            direction: direction,
            token: token,
            startedURL: tab.url,
            expectedURL: expectedURL,
            session: tab.session
        )
        pendingHistoryNavigations[tab.id] = pending
        
        let tabID = tab.id
        pending.fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.pendingHistoryFallbackDelayNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.handlePendingHistoryFallback(for: tabID, token: token)
            }
        }
    }
    
    @MainActor
    private func handlePendingHistoryFallback(for tabID: UUID, token: UUID) {
        guard let pending = pendingHistoryNavigations[tabID],
              pending.token == token,
              let location = tabLocation(for: tabID) else {
            return
        }
        
        let tab = tabs(for: location.mode)[location.index]
        guard pending.session === tab.session else {
            clearPendingHistoryNavigation(for: tabID, token: token)
            return
        }
        
        guard normalizedNavigationURL(tab.url) == normalizedNavigationURL(pending.startedURL) else {
            clearPendingHistoryNavigation(for: tabID, token: token)
            return
        }
        
        let targetURL: String?
        switch pending.direction {
        case .back:
            targetURL = sessionStore.previousURL(for: tab.id)
        case .forward:
            targetURL = sessionStore.nextURL(for: tab.id)
        }
        
        clearPendingHistoryNavigation(for: tabID, token: token)
        guard let targetURL else {
            applyNavigationState(to: tab)
            notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
            return
        }
        
        _ = sessionStore.setOwnsNav(true, for: tab.id)
        applyNavigationState(to: tab)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
        loadHistoryURL(targetURL, in: tab)
    }
    
    private func makeTab(windowId: String?, isPrivate: Bool) -> Tab {
        let tab = Tab(session: createSession(windowId: windowId, isPrivate: isPrivate), isPrivate: isPrivate)
        let controller = NowPlayingController(session: tab.session)
        tab.session.mediaSessionDelegate = controller
        tab.nowPlayingController = controller
        return tab
    }
    
    private func bindDelegates(to session: GeckoSession, for tab: Tab) {
        session.contentDelegate = self
        session.progressDelegate = self
        session.navigationDelegate = self
        let controller = NowPlayingController(session: session)
        session.mediaSessionDelegate = controller
        tab.nowPlayingController = controller
    }
    
    private func applyTransferredState(to tab: Tab, url: String, title: String?) {
        tab.url = url
        if let title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tab.title = title
        }
        tab.pendingDisplayText = nil
        tab.suppressInitialNavigation = true
        tab.favicon = cachedFavicon(for: url)
        tab.session.updateSettings(GeckoSessionController.shared.sessionSettings(for: url, tabID: tab.id))
    }
    
    private func recordTransferredHistory(for tab: Tab, title: String?) {
        guard !tab.isPrivate,
              let url = remoteURL(from: tab.url) else {
            return
        }
        
        historyStore.recordVisit(url: url, title: tab.title)
        if let title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            historyStore.updateTitle(for: url, title: title)
        }
    }
    
    private func restoredURL(from value: String?) -> String? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty,
              trimmedValue.lowercased() != "about:blank" else {
            return nil
        }
        
        return trimmedValue
    }
    
    private func restoredURL(from value: String?, fallback fallbackValue: String?) -> String? {
        restoredURL(from: value) ?? restoredURL(from: fallbackValue)
    }
    
    private func remoteURL(from value: String?) -> URL? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: trimmedValue),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        
        return url
    }
    
    private func cachedFavicon(for value: String?) -> UIImage? {
        guard let url = remoteURL(from: value) else {
            return nil
        }
        
        return faviconStore.cachedImage(for: url)
    }
    
    private func scheduleFaviconUpdate(forTabAt index: Int, mode: TabMode? = nil) {
        let mode = mode ?? selectedTabMode
        guard tabs(for: mode).indices.contains(index) else {
            return
        }
        
        let tab = tabs(for: mode)[index]
        cancelFaviconTask(for: tab.id)
        
        let cachedImage = cachedFavicon(for: tab.url)
        tab.favicon = cachedImage
        notifyUpdate(at: index, mode: mode, reason: .favicon)
        
        guard cachedImage == nil,
              let url = remoteURL(from: tab.url) else {
            return
        }
        
        let tabID = tab.id
        let expectedURL = url.absoluteString
        faviconTasks[tabID] = Task { [weak self] in
            guard let self else {
                return
            }
            
            let image = await self.faviconStore.resolveFavicon(for: url)
            guard !Task.isCancelled else {
                return
            }
            
            await MainActor.run {
                self.applyResolvedFavicon(image, toTabWithID: tabID, expectedURL: expectedURL)
            }
        }
    }
    
    @MainActor
    private func applyResolvedFavicon(_ image: UIImage?, toTabWithID tabID: UUID, expectedURL: String) {
        defer {
            faviconTasks.removeValue(forKey: tabID)
        }
        
        guard let location = tabLocation(for: tabID),
              tabs(for: location.mode)[location.index].url == expectedURL else {
            return
        }
        
        tabs(for: location.mode)[location.index].favicon = image
        notifyUpdate(at: location.index, mode: location.mode, reason: .favicon)
    }
    
    private func restoreTabsIfNeeded() -> Bool {
        guard regularTabs.isEmpty && privateTabs.isEmpty else {
            return true
        }
        
        let snapshot = store.loadSnapshot()
        guard !snapshot.regularTabs.isEmpty || !snapshot.privateTabs.isEmpty else {
            return false
        }
        
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
        
        selectedRegularTabIndex = snapshot.selectedRegularTabID.flatMap { selectedTabID in
            regularTabs.firstIndex(where: { $0.id == selectedTabID })
        } ?? (regularTabs.isEmpty ? -1 : 0)
        
        selectedPrivateTabIndex = snapshot.selectedPrivateTabID.flatMap { selectedTabID in
            privateTabs.firstIndex(where: { $0.id == selectedTabID })
        } ?? (privateTabs.isEmpty ? -1 : 0)
        
        selectedTabMode = snapshot.selectedTabMode
        
        if tabs(for: selectedTabMode).isEmpty {
            selectedTabMode = regularTabs.isEmpty ? .private : .regular
        }
        
        delegate?.tabManagerDidChangeTabs(self)
        
        selectTab(at: max(selectedIndex(for: selectedTabMode), 0), mode: selectedTabMode)
        return true
    }
    
    private func loadRestoredURLIfNeeded(for index: Int, mode: TabMode) {
        guard tabs(for: mode).indices.contains(index) else {
            return
        }
        
        let tab = tabs(for: mode)[index]
        guard let url = tab.pendingRestoreURL else {
            return
        }
        
        tab.pendingRestoreURL = nil
        tab.suppressInitialNavigation = true
        loadURL(url, in: tab)
    }
    
    func createInitialTab() {
        if restoreTabsIfNeeded() {
            return
        }
        
        addTab(selecting: true, windowId: nil, at: nil, isPrivate: false)
    }
    
    @discardableResult
    func addTab(selecting: Bool, windowId: String? = nil, at insertionIndex: Int? = nil, isPrivate: Bool = false) -> Int {
        let tab = makeTab(windowId: windowId, isPrivate: isPrivate)
        let mode: TabMode = isPrivate ? .private : .regular
        let count = tabs(for: mode).count
        let index = min(max(insertionIndex ?? count, 0), count)
        
        if mode == .regular {
            if index == regularTabs.count {
                regularTabs.append(tab)
            } else {
                regularTabs.insert(tab, at: index)
                if selectedRegularTabIndex >= index {
                    selectedRegularTabIndex += 1
                }
            }
        } else {
            if index == privateTabs.count {
                privateTabs.append(tab)
            } else {
                privateTabs.insert(tab, at: index)
                if selectedPrivateTabIndex >= index {
                    selectedPrivateTabIndex += 1
                }
            }
        }
        
        delegate?.tabManagerDidChangeTabs(self)
        
        if selecting {
            selectTab(at: index, mode: mode)
        } else {
            persistState()
        }
        
        return index
    }
    
    @discardableResult
    func addTab(using session: GeckoSession, url: String, title: String?, selecting: Bool, at insertionIndex: Int?, isPrivate: Bool = false) -> Int {
        let tab = Tab(session: session, isPrivate: isPrivate)
        let mode: TabMode = isPrivate ? .private : .regular
        bindDelegates(to: session, for: tab)
        applyTransferredState(to: tab, url: url, title: title)
        recordNavigation(url, for: tab)
        
        let count = tabs(for: mode).count
        let index = min(max(insertionIndex ?? count, 0), count)
        if mode == .regular {
            if index == regularTabs.count {
                regularTabs.append(tab)
            } else {
                regularTabs.insert(tab, at: index)
                if selectedRegularTabIndex >= index {
                    selectedRegularTabIndex += 1
                }
            }
        } else {
            if index == privateTabs.count {
                privateTabs.append(tab)
            } else {
                privateTabs.insert(tab, at: index)
                if selectedPrivateTabIndex >= index {
                    selectedPrivateTabIndex += 1
                }
            }
        }
        
        delegate?.tabManagerDidChangeTabs(self)
        notifyUpdate(at: index, mode: mode, reason: .location)
        notifyUpdate(at: index, mode: mode, reason: .title)
        scheduleFaviconUpdate(forTabAt: index, mode: mode)
        recordTransferredHistory(for: tab, title: title)
        
        if selecting {
            selectedTabMode = mode
            delegate?.tabManager(self, animateNewTabSelectionAt: index) { [weak self] in
                self?.selectTab(at: index, mode: mode)
            }
            session.setFocused(true)
        } else {
            persistState()
        }
        
        return index
    }
    
    func selectTab(at index: Int, mode: TabMode? = nil) {
        let mode = mode ?? selectedTabMode
        guard tabs(for: mode).indices.contains(index) else {
            return
        }
        
        let previousMode = selectedTabMode
        let previousIndex = previousMode == mode && tabs(for: previousMode).indices.contains(selectedTabIndex) ? selectedTabIndex : nil
        
        selectedTabMode = mode
        selectionCounter += 1
        setSelectedIndex(index, for: mode)
        tabs(for: mode)[index].selectionOrder = selectionCounter
        tabs(for: mode)[index].session.setActive(true)
        applyNavigationState(to: tabs(for: mode)[index])
        
        delegate?.tabManager(self, didSelectTabAt: index, previousIndex: previousIndex)
        loadRestoredURLIfNeeded(for: index, mode: mode)
        persistState()
    }
    
    func moveTab(from sourceIndex: Int, to destinationIndex: Int, mode: TabMode? = nil) {
        let mode = mode ?? selectedTabMode
        guard tabs(for: mode).indices.contains(sourceIndex),
              tabs(for: mode).indices.contains(destinationIndex),
              sourceIndex != destinationIndex else {
            return
        }
        
        let selectedTabID = tabs(for: mode)[safe: selectedIndex(for: mode)]?.id
        if mode == .regular {
            let movedTab = regularTabs.remove(at: sourceIndex)
            regularTabs.insert(movedTab, at: destinationIndex)
        } else {
            let movedTab = privateTabs.remove(at: sourceIndex)
            privateTabs.insert(movedTab, at: destinationIndex)
        }
        
        if let selectedTabID,
           let selectedIndex = tabs(for: mode).firstIndex(where: { $0.id == selectedTabID }) {
            setSelectedIndex(selectedIndex, for: mode)
        }
        
        persistState()
    }
    
    func removeTab(at index: Int, mode: TabMode? = nil) {
        let mode = mode ?? selectedTabMode
        guard tabs(for: mode).indices.contains(index) else {
            return
        }
        
        let wasSelected = mode == selectedTabMode && index == selectedTabIndex
        let removedTab: Tab
        if mode == .regular {
            removedTab = regularTabs.remove(at: index)
        } else {
            removedTab = privateTabs.remove(at: index)
        }
        cancelFaviconTask(for: removedTab.id)
        clearPendingNavigationState(for: removedTab.id)
        GeckoSessionController.shared.clearOverrides(forTabID: removedTab.id)
        sessionStore.removeSession(for: removedTab.id)
        
        if tabs(for: mode).isEmpty {
            setSelectedIndex(-1, for: mode)
        } else if index < selectedIndex(for: mode) {
            setSelectedIndex(selectedIndex(for: mode) - 1, for: mode)
        }
        
        if regularTabs.isEmpty && privateTabs.isEmpty {
            delegate?.tabManagerDidChangeTabs(self)
            persistState()
            closeSession(removedTab.session)
            return
        }
        
        delegate?.tabManagerDidChangeTabs(self)
        
        if wasSelected {
            if !tabs(for: mode).isEmpty {
                selectTab(at: min(index, tabs(for: mode).count - 1), mode: mode)
            } else {
                let fallbackMode: TabMode = mode == .regular ? .private : .regular
                selectTab(at: max(selectedIndex(for: fallbackMode), 0), mode: fallbackMode)
            }
        } else {
            persistState()
        }
        
        closeSession(removedTab.session)
    }
    
    func removeAllTabs(mode: TabMode? = nil) {
        let mode = mode ?? selectedTabMode
        guard !tabs(for: mode).isEmpty else {
            return
        }
        
        let removedTabs = tabs(for: mode)
        if mode == .regular {
            regularTabs.removeAll(keepingCapacity: true)
            selectedRegularTabIndex = -1
        } else {
            privateTabs.removeAll(keepingCapacity: true)
            selectedPrivateTabIndex = -1
        }
        removedTabs.forEach { cancelFaviconTask(for: $0.id) }
        removedTabs.forEach { clearPendingNavigationState(for: $0.id) }
        removedTabs.forEach { GeckoSessionController.shared.clearOverrides(forTabID: $0.id) }
        removedTabs.forEach { sessionStore.removeSession(for: $0.id) }
        delegate?.tabManagerDidChangeTabs(self)
        
        if mode == selectedTabMode {
            if mode == .private && !regularTabs.isEmpty {
                selectTab(at: max(selectedRegularTabIndex, 0), mode: .regular)
            } else if mode == .regular && !privateTabs.isEmpty {
                selectTab(at: max(selectedPrivateTabIndex, 0), mode: .private)
            } else {
                persistState()
            }
        } else {
            persistState()
        }
        
        removedTabs.forEach { closeSession($0.session) }
    }
    
    func browse(to term: String) {
        guard let tab = selectedTab else {
            return
        }
        browse(to: term, in: tab)
    }
    
    func browse(to term: String, in tab: Tab) {
        let trimmedValue = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return
        }
        
        tab.suppressInitialNavigation = false
        tab.pendingDisplayText = trimmedValue
        clearPendingNavigationState(for: tab.id)
        pendingObservedNavigationIntents[tab.id] = .normal
        
        let fullRange = NSRange(location: 0, length: (trimmedValue as NSString).length)
        let isURL = isURLLenient.firstMatch(in: trimmedValue, range: fullRange) != nil
        
        if isURL {
            loadURL(trimmedValue, in: tab)
            return
        }
        
        let searchTarget = searchURL(for: trimmedValue)
        loadURL(searchTarget, in: tab)
    }
    
    func goBack() {
        guard let tab = selectedTab else {
            return
        }
        guard pendingHistoryNavigations[tab.id] == nil else {
            return
        }
        
        let snapshot = sessionStore.loadSnapshot(for: tab.id)
        if !snapshot.ownsNav && tab.sessionCanGoBack {
            startPendingHistoryNavigation(for: tab, direction: .back, expectedURL: snapshot.backList.last)
            tab.session.goBack()
            return
        }
        
        guard let url = sessionStore.previousURL(for: tab.id) else {
            return
        }
        
        _ = sessionStore.setOwnsNav(true, for: tab.id)
        applyNavigationState(to: tab)
        delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .navigationState)
        loadHistoryURL(url, in: tab)
    }
    
    func goForward() {
        guard let tab = selectedTab else {
            return
        }
        guard pendingHistoryNavigations[tab.id] == nil else {
            return
        }
        
        let snapshot = sessionStore.loadSnapshot(for: tab.id)
        if !snapshot.ownsNav && tab.sessionCanGoForward {
            startPendingHistoryNavigation(for: tab, direction: .forward, expectedURL: snapshot.forwardList.first)
            tab.session.goForward()
            return
        }
        
        guard let url = sessionStore.nextURL(for: tab.id) else {
            return
        }
        
        _ = sessionStore.setOwnsNav(true, for: tab.id)
        applyNavigationState(to: tab)
        delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .navigationState)
        loadHistoryURL(url, in: tab)
    }
    
    func markNextNavigationAsReplace(for tab: Tab) {
        clearPendingNavigationState(for: tab.id)
        replaceNavigationTabIDs.insert(tab.id)
        pendingObservedNavigationIntents[tab.id] = .replace
    }
    
    func replaceSession(with session: GeckoSession, url: String, title: String?) {
        guard let tab = selectedTab else {
            return
        }
        
        let oldSession = tab.session
        closeSession(oldSession)
        clearPendingNavigationState(for: tab.id)
        
        bindDelegates(to: session, for: tab)
        tab.session = session
        applyTransferredState(to: tab, url: url, title: title)
        tab.sessionCanGoBack = false
        tab.sessionCanGoForward = false
        recordNavigation(url, for: tab)
        _ = sessionStore.setOwnsNav(true, for: tab.id)
        applyNavigationState(to: tab)
        session.setActive(true)
        session.setFocused(true)
        
        delegate?.tabManagerDidChangeTabs(self)
        delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .location)
        delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .title)
        scheduleFaviconUpdate(forTabAt: selectedTabIndex)
        persistState()
        recordTransferredHistory(for: tab, title: title)
    }
    
    func tabIndex(for session: GeckoSession) -> Int? {
        tabs(for: selectedTabMode).firstIndex(where: { $0.session === session })
    }
    
    func shareableURL(for tab: Tab) -> URL? {
        guard let value = tab.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.lowercased() != "about:blank",
              let url = URL(string: value),
              let scheme = url.scheme,
              !scheme.isEmpty else {
            return nil
        }
        return url
    }
    
    func updateThumbnail(_ image: UIImage?, forTabAt index: Int) {
        guard tabs(for: selectedTabMode).indices.contains(index) else {
            return
        }
        
        let tab = tabs(for: selectedTabMode)[index]
        tab.thumbnail = image
        store.saveThumbnail(image, for: tab.id)
    }
    
    private func createSession(windowId: String?, isPrivate: Bool) -> GeckoSession {
        let session = GeckoSession()
        session.isPrivateMode = isPrivate
        session.contentDelegate = self
        session.progressDelegate = self
        session.navigationDelegate = self
        session.open(windowId: windowId)
        return session
    }
}

extension TabManagerImplementation: ContentDelegate {
    func onTitleChange(session: GeckoSession, title: String) {
        guard let location = tabLocation(for: session) else {
            return
        }
        
        let tab = tabs(for: location.mode)[location.index]
        tab.title = title
        if !tab.isPrivate,
           let url = remoteURL(from: tab.url) {
            historyStore.updateTitle(for: url, title: title)
        }
        notifyUpdate(at: location.index, mode: location.mode, reason: .title)
        persistState()
    }
    
    func onPreviewImage(session: GeckoSession, previewImageUrl: String) {}
    
    func onFocusRequest(session: GeckoSession) {
        guard selectedTab?.session === session else {
            return
        }
        
        session.setActive(true)
        session.setFocused(true)
    }
    
    func onCloseRequest(session: GeckoSession) {
        guard let location = tabLocation(for: session) else {
            return
        }
        removeTab(at: location.index, mode: location.mode)
    }
    
    func onFullScreen(session: GeckoSession, fullScreen: Bool) {
        guard selectedTab?.session === session else {
            return
        }
        
        delegate?.tabManager(self, didChangeFullscreen: fullScreen, for: session)
    }
    
    func onMetaViewportFitChange(session: GeckoSession, viewportFit: String) {}
    
    func onProductUrl(session: GeckoSession) {}
    
    func onContextMenu(session: GeckoSession, screenX: Int, screenY: Int, element: ContextElement) {
        guard selectedTab?.session === session else {
            return
        }
        
        let hasImageSource = element.type == .image && element.srcUri?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasLink = element.linkUri?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasImageSource || hasLink else {
            return
        }
        
        delegate?.tabManager(self, didRequestContextMenuAt: CGPoint(x: screenX, y: screenY), for: element, in: session)
    }
    
    func onCrash(session: GeckoSession) {
        guard let location = tabLocation(for: session) else {
            return
        }
        removeTab(at: location.index, mode: location.mode)
    }
    
    func onKill(session: GeckoSession) {
        guard let location = tabLocation(for: session) else {
            return
        }
        removeTab(at: location.index, mode: location.mode)
    }
    
    func onFirstComposite(session: GeckoSession) {}
    
    func onFirstContentfulPaint(session: GeckoSession) {}
    
    func onPaintStatusReset(session: GeckoSession) {}
    
    func onWebAppManifest(session: GeckoSession, manifest: Any) {}
    
    func onSlowScript(session: GeckoSession, scriptFileName: String) async -> SlowScriptResponse {
        .halt
    }
    
    func onShowDynamicToolbar(session: GeckoSession) {}
    
    func onCookieBannerDetected(session: GeckoSession) {}
    
    func onCookieBannerHandled(session: GeckoSession) {}
    
    func onExternalResponse(session: GeckoSession, response: ExternalResponseInfo) {
        if delegate?.tabManager(self, shouldHandleExternalResponse: response, for: session) == true {
            return
        }
        guard let download = DownloadStore.shared.prepareDownload(from: response) else {
            return
        }
        
        delegate?.tabManager(self, didRequestDownload: download)
    }
    
    func onSavePdf(session: GeckoSession, request: SavePdfInfo) {
        guard let download = DownloadStore.shared.prepareDownload(from: request) else {
            return
        }
        
        delegate?.tabManager(self, didRequestDownload: download)
    }
}

extension TabManagerImplementation: NavigationDelegate {
    func onLocationChange(session: GeckoSession, url: String?, permissions: [ContentPermission]) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        let observedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = observedURL?.lowercased()
        
        if tab.suppressInitialNavigation,
           let normalizedURL,
           normalizedURL.hasPrefix("about:blank") {
            return
        }
        
        guard let observedURL,
              !observedURL.isEmpty else {
            return
        }
        
        let observedIntent: TabSessionStore.ObservedNavigationIntent?
        let pendingHistory = pendingHistoryNavigations[tab.id]
        if let pendingHistory,
           pendingHistory.session === session {
            if shouldWaitForMeaningfulHistoryChange(pendingHistory, observedURL: observedURL) {
                return
            }
            observedIntent = observedIntent(for: pendingHistory.direction)
            clearPendingHistoryNavigation(for: tab.id, token: pendingHistory.token)
            pendingObservedNavigationIntents.removeValue(forKey: tab.id)
        } else {
            if pendingHistory != nil {
                clearPendingHistoryNavigation(for: tab.id)
            }
            if replaceNavigationTabIDs.contains(tab.id) {
                observedIntent = .replace
                pendingObservedNavigationIntents[tab.id] = .replace
            } else {
                observedIntent = pendingObservedNavigationIntents.removeValue(forKey: tab.id)
            }
        }
        tab.suppressInitialNavigation = false
        
        session.updateSettings(GeckoSessionController.shared.sessionSettings(for: observedURL, tabID: tab.id))
        SitePermissionController.shared.applyPermissions(to: session, urlString: observedURL)
        
        tab.url = observedURL
        recordNavigation(observedURL, for: tab, intent: observedIntent)
        tab.pendingDisplayText = nil
        tab.favicon = nil
        notifyUpdate(at: location.index, mode: location.mode, reason: .location)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
        scheduleFaviconUpdate(forTabAt: location.index, mode: location.mode)
        persistState()
        
        guard !tab.isPrivate,
              let url = remoteURL(from: tab.url) else {
            return
        }
        
        historyStore.recordVisit(url: url, title: tab.title)
    }
    
    func onCanGoBack(session: GeckoSession, canGoBack: Bool) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        
        tab.sessionCanGoBack = canGoBack
        applyNavigationState(to: tab)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
    }
    
    func onCanGoForward(session: GeckoSession, canGoForward: Bool) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        
        tab.sessionCanGoForward = canGoForward
        applyNavigationState(to: tab)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
    }
    
    func onLoadRequest(session: GeckoSession, request: LoadRequest) async -> AllowOrDeny {
        guard let location = tabLocation(for: session),
              case .current = request.target else {
            return .allow
        }

        let tab = tabs(for: location.mode)[location.index]
        if pendingHistoryNavigations[tab.id] == nil,
           pendingObservedNavigationIntents[tab.id] == nil,
           !replaceNavigationTabIDs.contains(tab.id) {
            pendingObservedNavigationIntents[tab.id] = .normal
        }

        return .allow
    }

    func onSubframeLoadRequest(session: GeckoSession, request: LoadRequest) async -> AllowOrDeny {
        .allow
    }
    
    func onNewSession(session: GeckoSession, uri: String, windowId: String) async -> GeckoSession? {
        let newSession = GeckoSession()
        
        let sourceLocation = tabLocation(for: session)
        let mode = sourceLocation?.mode ?? selectedTabMode
        let sourceIsPrivate = mode == .private
        newSession.isPrivateMode = sourceIsPrivate
        newSession.contentDelegate = self
        newSession.progressDelegate = self
        newSession.navigationDelegate = self
        let newTab = Tab(session: newSession, isPrivate: sourceIsPrivate)
        newSession.updateSettings(GeckoSessionController.shared.sessionSettings(for: uri, tabID: newTab.id))
        let controller = NowPlayingController(session: newSession)
        newSession.mediaSessionDelegate = controller
        SitePermissionController.shared.applyPermissions(to: newSession, urlString: uri)
        newTab.nowPlayingController = controller
        newTab.url = uri
        newTab.favicon = cachedFavicon(for: uri)
        recordNavigation(uri, for: newTab)
        
        let insertionIndex = sourceLocation.map { $0.index + 1 }
        let count = tabs(for: mode).count
        let index = min(max(insertionIndex ?? count, 0), count)
        if mode == .regular {
            if index == regularTabs.count {
                regularTabs.append(newTab)
            } else {
                regularTabs.insert(newTab, at: index)
                if selectedRegularTabIndex >= index {
                    selectedRegularTabIndex += 1
                }
            }
        } else {
            if index == privateTabs.count {
                privateTabs.append(newTab)
            } else {
                privateTabs.insert(newTab, at: index)
                if selectedPrivateTabIndex >= index {
                    selectedPrivateTabIndex += 1
                }
            }
        }
        
        delegate?.tabManagerDidChangeTabs(self)
        notifyUpdate(at: index, mode: mode, reason: .location)
        scheduleFaviconUpdate(forTabAt: index, mode: mode)
        persistState()
        selectedTabMode = mode
        delegate?.tabManager(self, animateNewTabSelectionAt: index) { [weak self] in
            self?.selectTab(at: index, mode: mode)
        }
        return newSession
    }
}

extension TabManagerImplementation: ProgressDelegate {
    func onPageStart(session: GeckoSession, url: String) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        
        let currentHost = tab.url.flatMap { GeckoSessionController.shared.extractHost(from: $0) }
        let requestedHost = GeckoSessionController.shared.extractHost(from: url)
        let desiredSettings = GeckoSessionController.shared.sessionSettings(for: url, tabID: tab.id)
        
        if currentHost != nil,
           requestedHost != nil,
           currentHost != requestedHost,
           (desiredSettings.userAgentOverride != session.userAgentOverride ||
            desiredSettings.userAgentMode != session.userAgentMode ||
            desiredSettings.viewportMode != session.viewportMode) {
            loadURL(url, in: tab)
        }
        
        tab.isLoading = true
        tab.progress = 0
        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
    }
    
    func onPageStop(session: GeckoSession, success: Bool) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        if replaceNavigationTabIDs.remove(tab.id) != nil,
           pendingObservedNavigationIntents[tab.id] == .replace {
            pendingObservedNavigationIntents.removeValue(forKey: tab.id)
        }
        
        tab.isLoading = false
        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
        notifyUpdate(at: location.index, mode: location.mode, reason: .thumbnail)
    }
    
    func onProgressChange(session: GeckoSession, progress: Int) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        
        tab.progress = Float(progress) / 100
        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
    }
}
