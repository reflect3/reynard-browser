//
//  TabManagerImpl.swift
//  Reynard
//
//  Created by Minh Ton on 5/3/26.
//

import Foundation
import GeckoView
import UIKit

final class TabManagerImplementation: NSObject, TabManager {
    private static let sessionHistoryWatchdogDelayNanoseconds: UInt64 = 2_000_000_000
    
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

    var selectedTabIsNavigatingHistory: Bool {
        guard let tab = selectedTab else {
            return false
        }

        return tab.navigationTransaction?.isPendingHistoryNavigation == true
    }
    
    private weak var delegate: TabManagerDelegate?
    private let store: TabManagementStore
    private let faviconStore: FaviconStore
    private let historyStore: HistoryStore
    private let sessionStore: TabSessionStore
    private var faviconTasks: [UUID: Task<Void, Never>] = [:]
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
    
    private func applyNavigationState(to tab: Tab, from snapshot: TabSessionStore.Snapshot) {
        if tab.sessionCanGoBack || tab.sessionCanGoForward {
            tab.canNavigateBack = tab.sessionCanGoBack
            tab.canNavigateForward = tab.sessionCanGoForward
        } else if snapshot.ownsNav {
            tab.canNavigateBack = snapshot.canGoBack
            tab.canNavigateForward = snapshot.canGoForward
        } else {
            tab.canNavigateBack = false
            tab.canNavigateForward = false
        }
    }
    
    private func applyNavigationState(to tab: Tab) {
        let snapshot = sessionStore.loadSnapshot(for: tab.id)
        applyNavigationState(to: tab, from: snapshot)
    }
    
    @discardableResult
    private func recordNavigation(
        _ url: String,
        for tab: Tab,
        intent: TabSessionStore.ObservedNavigationIntent? = .normal
    ) -> TabSessionStore.Snapshot? {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty,
              trimmedURL.lowercased() != "about:blank" else {
            return nil
        }
        
        let snapshot = sessionStore.recordObservedNavigation(to: trimmedURL, for: tab.id, intent: intent)
        applyNavigationState(to: tab, from: snapshot)
        return snapshot
    }
    
    private func observedNavigationIntent(forHistoryDirection direction: NavigationTransaction.Direction) -> TabSessionStore.ObservedNavigationIntent {
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
    
    private func clearPendingNavigationState(for tabID: UUID) {
        guard let location = tabLocation(for: tabID) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        cancelNavigationTransaction(for: tab)
    }

    private func clearTabScopedState(for tab: Tab) {
        cancelFaviconTask(for: tab.id)
        clearPendingNavigationState(for: tab.id)
        GeckoSessionController.shared.clearOverrides(forTabID: tab.id)
        SitePermissionStore.shared.removePrivateTabPerms(for: tab.session)
        sessionStore.removeSession(for: tab.id)
    }

    @discardableResult
    private func beginNavigationTransaction(
        for tab: Tab,
        kind: NavigationTransaction.Kind,
        requestedURL: String? = nil,
        expectedURL: String? = nil,
        usesReplaceHistory: Bool = false,
        source: NavigationTransaction.Source
    ) -> NavigationTransaction {
        cancelNavigationTransaction(for: tab)
        let transaction = NavigationTransaction(
            kind: kind,
            startedURL: tab.url,
            requestedURL: requestedURL,
            expectedURL: expectedURL,
            session: tab.session,
            usesReplaceHistory: usesReplaceHistory,
            source: source,
            startedCanGoBack: tab.sessionCanGoBack,
            startedCanGoForward: tab.sessionCanGoForward
        )
        tab.navigationTransaction = transaction
        return transaction
    }

    private func activeNavigationTransaction(for tab: Tab, session: GeckoSession? = nil) -> NavigationTransaction? {
        guard let transaction = tab.navigationTransaction else {
            return nil
        }
        if let session,
           transaction.session !== session {
            cancelNavigationTransaction(for: tab)
            return nil
        }
        return transaction
    }

    private func cancelNavigationTransaction(for tab: Tab) {
        tab.navigationTransaction?.watchdogTask?.cancel()
        tab.navigationTransaction?.phase = .cancelled
        tab.navigationTransaction = nil
    }

    private func finishNavigationTransaction(for tab: Tab, transaction: NavigationTransaction? = nil) {
        guard let current = tab.navigationTransaction else {
            return
        }
        if let transaction,
           current.id != transaction.id {
            return
        }
        current.watchdogTask?.cancel()
        current.phase = .committed
        tab.navigationTransaction = nil
    }

    private func markNavigationTransactionCommitted(for tab: Tab, transaction: NavigationTransaction) {
        guard tab.navigationTransaction?.id == transaction.id else {
            return
        }

        transaction.phase = .committed
    }

    private func completeSessionHistoryTransactionIfNavigationStateChanged(
        for tab: Tab,
        at location: (mode: TabMode, index: Int)
    ) {
        guard let transaction = activeNavigationTransaction(for: tab),
              transaction.isPendingHistoryNavigation,
              case .sessionHistory = transaction.kind else {
            return
        }

        let navigationStateChanged = tab.sessionCanGoBack != transaction.startedCanGoBack ||
            tab.sessionCanGoForward != transaction.startedCanGoForward
        guard navigationStateChanged else {
            return
        }

        markNavigationTransactionCommitted(for: tab, transaction: transaction)
        applyNavigationState(to: tab)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
    }

    private func isCrashRecoveryTransaction(_ transaction: NavigationTransaction) -> Bool {
        if case .crashRecovery = transaction.source {
            return true
        }

        return false
    }

    private func terminationReason(for tab: Tab) -> ContentTerminationReason {
        switch tab.contentTerminationState {
        case let .crashed(_, reason), let .recovering(_, reason):
            return reason
        case .normal:
            return .crash
        }
    }

    private func recoveryTargetURL(for tab: Tab, transaction: NavigationTransaction) -> String? {
        transaction.recoveryTargetURL ?? transaction.requestedURL ?? transaction.observedURL ?? tab.crashedURL ?? tab.url
    }

    private func updateCrashRecoveryStateAfterPageStop(
        for tab: Tab,
        transaction: NavigationTransaction,
        success: Bool,
        at location: (mode: TabMode, index: Int)
    ) {
        guard isCrashRecoveryTransaction(transaction) else {
            return
        }

        if success,
           transaction.hasSatisfiedRecoveryTarget {
            tab.contentTerminationState = .normal
        } else {
            tab.contentTerminationState = .crashed(
                url: recoveryTargetURL(for: tab, transaction: transaction),
                reason: terminationReason(for: tab)
            )
        }

        notifyUpdate(at: location.index, mode: location.mode, reason: .contentState)
    }

    private func dispatchLoad(_ transaction: NavigationTransaction, in tab: Tab) {
        guard let requestedURL = transaction.requestedURL else {
            return
        }

        transaction.phase = .loadRequested
        tab.session.updateSettings(GeckoSessionController.shared.sessionSettings(for: requestedURL, tabID: tab.id))
        if transaction.usesReplaceHistory {
            tab.session.load(requestedURL, flags: GeckoSessionLoadFlags.replaceHistory)
        } else {
            tab.session.load(requestedURL)
        }
    }

    private func startSessionHistoryWatchdog(for tab: Tab, transactionID: UUID) {
        tab.navigationTransaction?.watchdogTask?.cancel()
        let tabID = tab.id
        tab.navigationTransaction?.watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.sessionHistoryWatchdogDelayNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.handleSessionHistoryWatchdog(for: tabID, transactionID: transactionID)
            }
        }
    }

    @MainActor
    private func handleSessionHistoryWatchdog(for tabID: UUID, transactionID: UUID) {
        guard let location = tabLocation(for: tabID) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        guard let transaction = tab.navigationTransaction,
              transaction.id == transactionID else {
            return
        }

        if case .committed = transaction.phase {
            tab.navigationTransaction = nil
            applyNavigationState(to: tab)
            notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
            return
        }

        transaction.phase = .cancelled
        tab.navigationTransaction = nil
        applyNavigationState(to: tab)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
    }

    private func handleContentTermination(session: GeckoSession, reason: ContentTerminationReason) {
        guard let location = tabLocation(for: session) else {
            return
        }

        let tab = tabs(for: location.mode)[location.index]
        let crashedURL = tab.url
        clearPendingNavigationState(for: tab.id)
        closeSession(tab.session)

        let replacementSession = createSession(windowId: nil, isPrivate: tab.isPrivate)
        let controller = NowPlayingController(session: replacementSession)
        replacementSession.mediaSessionDelegate = controller
        tab.session = replacementSession
        tab.nowPlayingController = controller
        tab.contentTerminationState = .crashed(url: crashedURL, reason: reason)
        tab.isLoading = false
        tab.progress = 0
        tab.pendingDisplayText = nil
        tab.suppressInitialNavigation = true
        tab.sessionCanGoBack = false
        tab.sessionCanGoForward = false
        applyNavigationState(to: tab)

        if location.mode == selectedTabMode,
           location.index == selectedTabIndex {
            replacementSession.setActive(true)
            replacementSession.setFocused(true)
        }

        delegate?.tabManagerDidChangeTabs(self)
        notifyUpdate(at: location.index, mode: location.mode, reason: .contentState)
        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
        persistState()
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
        clearTabScopedState(for: removedTab)
        
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
        removedTabs.forEach { clearTabScopedState(for: $0) }
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
        tab.contentTerminationState = .normal

        let fullRange = NSRange(location: 0, length: (trimmedValue as NSString).length)
        let isURL = isURLLenient.firstMatch(in: trimmedValue, range: fullRange) != nil
        let targetURL = isURL ? trimmedValue : searchURL(for: trimmedValue)
        let transaction = beginNavigationTransaction(
            for: tab,
            kind: .normal,
            requestedURL: targetURL,
            source: .userNavigation
        )
        dispatchLoad(transaction, in: tab)

        if let location = tabLocation(for: tab.id) {
            notifyUpdate(at: location.index, mode: location.mode, reason: .contentState)
        }
    }
    
    func goBack() {
        guard let tab = selectedTab else {
            return
        }
        guard tab.navigationTransaction?.isPendingHistoryNavigation != true else {
            return
        }
        
        let snapshot = sessionStore.loadSnapshot(for: tab.id)
        if tab.sessionCanGoBack {
            let transaction = beginNavigationTransaction(
                for: tab,
                kind: .sessionHistory(.back),
                expectedURL: snapshot.backList.last,
                source: .historyButton
            )
            delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .navigationState)
            tab.session.goBack()
            startSessionHistoryWatchdog(for: tab, transactionID: transaction.id)
            return
        }
        
        guard let url = sessionStore.peekPreviousURL(for: tab.id) else {
            return
        }
        guard normalizedNavigationURL(url) != normalizedNavigationURL(tab.url) else {
            applyNavigationState(to: tab)
            delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .navigationState)
            return
        }
        
        let transaction = beginNavigationTransaction(
            for: tab,
            kind: .applicationHistory(.back),
            requestedURL: url,
            expectedURL: url,
            usesReplaceHistory: true,
            source: .restoredAppHistory
        )
        _ = sessionStore.setOwnsNav(true, for: tab.id)
        applyNavigationState(to: tab)
        delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .navigationState)
        dispatchLoad(transaction, in: tab)
    }
    
    func goForward() {
        guard let tab = selectedTab else {
            return
        }
        guard tab.navigationTransaction?.isPendingHistoryNavigation != true else {
            return
        }
        
        let snapshot = sessionStore.loadSnapshot(for: tab.id)
        if tab.sessionCanGoForward {
            let transaction = beginNavigationTransaction(
                for: tab,
                kind: .sessionHistory(.forward),
                expectedURL: snapshot.forwardList.first,
                source: .historyButton
            )
            delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .navigationState)
            tab.session.goForward()
            startSessionHistoryWatchdog(for: tab, transactionID: transaction.id)
            return
        }
        
        guard let url = sessionStore.peekNextURL(for: tab.id) else {
            return
        }
        guard normalizedNavigationURL(url) != normalizedNavigationURL(tab.url) else {
            applyNavigationState(to: tab)
            delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .navigationState)
            return
        }
        
        let transaction = beginNavigationTransaction(
            for: tab,
            kind: .applicationHistory(.forward),
            requestedURL: url,
            expectedURL: url,
            usesReplaceHistory: true,
            source: .restoredAppHistory
        )
        _ = sessionStore.setOwnsNav(true, for: tab.id)
        applyNavigationState(to: tab)
        delegate?.tabManager(self, didUpdateTabAt: selectedTabIndex, reason: .navigationState)
        dispatchLoad(transaction, in: tab)
    }
    
    func replaceCurrentEntry(with url: String, in tab: Tab) {
        tab.pendingDisplayText = url
        tab.suppressInitialNavigation = false
        let transaction = beginNavigationTransaction(
            for: tab,
            kind: .replace,
            requestedURL: url,
            usesReplaceHistory: true,
            source: .websiteModeChange
        )
        dispatchLoad(transaction, in: tab)
    }

    func recoverCrashedTab(_ tab: Tab) {
        guard let targetURL = tab.crashedURL ?? tab.url,
              !targetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let reason: ContentTerminationReason
        switch tab.contentTerminationState {
        case let .crashed(_, terminationReason), let .recovering(_, terminationReason):
            reason = terminationReason
        case .normal:
            reason = .crash
        }

        tab.contentTerminationState = .recovering(url: targetURL, reason: reason)
        tab.suppressInitialNavigation = false
        tab.pendingDisplayText = targetURL
        let transaction = beginNavigationTransaction(
            for: tab,
            kind: .normal,
            requestedURL: targetURL,
            source: .crashRecovery
        )
        dispatchLoad(transaction, in: tab)

        if let location = tabLocation(for: tab.id) {
            notifyUpdate(at: location.index, mode: location.mode, reason: .contentState)
        }
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
        handleContentTermination(session: session, reason: .crash)
    }
    
    func onKill(session: GeckoSession) {
        handleContentTermination(session: session, reason: .kill)
    }
    
    func onFirstComposite(session: GeckoSession) {}
    
    func onFirstContentfulPaint(session: GeckoSession) {
        guard let location = tabLocation(for: session) else {
            return
        }

        let tab = tabs(for: location.mode)[location.index]
        guard tab.contentTerminationState.isRecovering else {
            return
        }

        guard let transaction = activeNavigationTransaction(for: tab, session: session),
              isCrashRecoveryTransaction(transaction),
              transaction.hasSatisfiedRecoveryTarget else {
            return
        }

        tab.contentTerminationState = .normal
        notifyUpdate(at: location.index, mode: location.mode, reason: .contentState)
    }
    
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

        let transaction = activeNavigationTransaction(for: tab, session: session)
        tab.suppressInitialNavigation = false
        
        session.updateSettings(GeckoSessionController.shared.sessionSettings(for: observedURL, tabID: tab.id))
        SitePermissionController.shared.applyPermissions(to: session, urlString: observedURL)
        
        tab.url = observedURL
        if !tab.contentTerminationState.isRecovering {
            tab.contentTerminationState = .normal
        }

        if let transaction,
           transaction.hasCommittedLocation {
            if transaction.shouldTreatAdditionalLocationAsRedirectFinalization {
                transaction.recordLocationCommit(observedURL)
                recordNavigation(observedURL, for: tab, intent: .replace)
                markNavigationTransactionCommitted(for: tab, transaction: transaction)
            } else {
                finishNavigationTransaction(for: tab, transaction: transaction)
                _ = sessionStore.setOwnsNav(false, for: tab.id)
                recordNavigation(observedURL, for: tab, intent: nil)
            }
        } else if let transaction {
            if transaction.canAcceptPageStart {
                transaction.phase = .locationObserved
            }
            transaction.recordLocationCommit(observedURL)

            switch transaction.kind {
            case .applicationHistory(.back):
                let snapshot: TabSessionStore.Snapshot
                if let expectedURL = transaction.expectedURL {
                    snapshot = sessionStore.commitPreviousURL(expectedURL: expectedURL, resolvedURL: observedURL, for: tab.id)
                } else {
                    snapshot = sessionStore.loadSnapshot(for: tab.id)
                }
                applyNavigationState(to: tab, from: snapshot)
                markNavigationTransactionCommitted(for: tab, transaction: transaction)

            case .applicationHistory(.forward):
                let snapshot: TabSessionStore.Snapshot
                if let expectedURL = transaction.expectedURL {
                    snapshot = sessionStore.commitNextURL(expectedURL: expectedURL, resolvedURL: observedURL, for: tab.id)
                } else {
                    snapshot = sessionStore.loadSnapshot(for: tab.id)
                }
                applyNavigationState(to: tab, from: snapshot)
                markNavigationTransactionCommitted(for: tab, transaction: transaction)

            case let .sessionHistory(direction):
                if normalizedNavigationURL(transaction.startedURL) != normalizedNavigationURL(observedURL) {
                    _ = sessionStore.setOwnsNav(false, for: tab.id)
                    recordNavigation(observedURL, for: tab, intent: observedNavigationIntent(forHistoryDirection: direction))
                } else {
                    applyNavigationState(to: tab)
                }
                markNavigationTransactionCommitted(for: tab, transaction: transaction)

            case .replace:
                recordNavigation(observedURL, for: tab, intent: .replace)
                markNavigationTransactionCommitted(for: tab, transaction: transaction)

            case .normal:
                _ = sessionStore.setOwnsNav(false, for: tab.id)
                recordNavigation(observedURL, for: tab, intent: .normal)
                markNavigationTransactionCommitted(for: tab, transaction: transaction)
            }
        } else {
            _ = sessionStore.setOwnsNav(false, for: tab.id)
            recordNavigation(observedURL, for: tab, intent: nil)
        }
        tab.pendingDisplayText = nil
        tab.favicon = nil
        notifyUpdate(at: location.index, mode: location.mode, reason: .location)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
        notifyUpdate(at: location.index, mode: location.mode, reason: .contentState)
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
        completeSessionHistoryTransactionIfNavigationStateChanged(for: tab, at: location)
        applyNavigationState(to: tab)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
    }
    
    func onCanGoForward(session: GeckoSession, canGoForward: Bool) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        
        tab.sessionCanGoForward = canGoForward
        completeSessionHistoryTransactionIfNavigationStateChanged(for: tab, at: location)
        applyNavigationState(to: tab)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
    }
    
    func onLoadRequest(session: GeckoSession, request: LoadRequest) async -> AllowOrDeny {
        guard let location = tabLocation(for: session),
              case .current = request.target else {
            return .allow
        }

        let tab = tabs(for: location.mode)[location.index]
        if let transaction = activeNavigationTransaction(for: tab, session: session) {
            if transaction.isTerminal {
                finishNavigationTransaction(for: tab, transaction: transaction)
                let newTransaction = beginNavigationTransaction(
                    for: tab,
                    kind: .normal,
                    requestedURL: request.uri,
                    source: .geckoLoadRequest
                )
                newTransaction.recordLoadRequest(
                    uri: request.uri,
                    triggerUri: request.triggerUri,
                    isRedirect: request.isRedirect,
                    hasUserGesture: request.hasUserGesture,
                    isDirectNavigation: request.isDirectNavigation
                )
            } else {
                transaction.recordLoadRequest(
                    uri: request.uri,
                    triggerUri: request.triggerUri,
                    isRedirect: request.isRedirect,
                    hasUserGesture: request.hasUserGesture,
                    isDirectNavigation: request.isDirectNavigation
                )
                if case .created = transaction.phase {
                    transaction.phase = .loadRequested
                }
            }
        } else {
            let transaction = beginNavigationTransaction(
                for: tab,
                kind: .normal,
                requestedURL: request.uri,
                source: .geckoLoadRequest
            )
            transaction.recordLoadRequest(
                uri: request.uri,
                triggerUri: request.triggerUri,
                isRedirect: request.isRedirect,
                hasUserGesture: request.hasUserGesture,
                isDirectNavigation: request.isDirectNavigation
            )
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
        let transaction = activeNavigationTransaction(for: tab, session: session)
        if let transaction,
           case .committed = transaction.phase {
            // 已由 Gecko native state-change 完成的事务保持 committed，避免 UI pending 回跳。
        } else {
            transaction?.phase = .pageStarted
        }
        
        if currentHost != nil,
           requestedHost != nil,
           currentHost != requestedHost,
           (desiredSettings.userAgentOverride != session.userAgentOverride ||
            desiredSettings.userAgentMode != session.userAgentMode ||
            desiredSettings.viewportMode != session.viewportMode) {
            if transaction?.isHistoryNavigation == true {
                session.updateSettings(desiredSettings)
            } else {
                loadURL(url, in: tab)
            }
        }
        
        if !tab.contentTerminationState.isRecovering {
            tab.contentTerminationState = .normal
        }
        tab.isLoading = true
        tab.progress = 0
        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
        notifyUpdate(at: location.index, mode: location.mode, reason: .contentState)
    }
    
    func onPageStop(session: GeckoSession, success: Bool) {
        guard let location = tabLocation(for: session) else {
            return
        }
        let tab = tabs(for: location.mode)[location.index]
        if let transaction = activeNavigationTransaction(for: tab, session: session) {
            let wasCommitted: Bool
            if case .committed = transaction.phase {
                wasCommitted = true
            } else {
                wasCommitted = false
            }
            transaction.phase = .stopped
            if success || wasCommitted || transaction.hasCommittedLocation {
                updateCrashRecoveryStateAfterPageStop(
                    for: tab,
                    transaction: transaction,
                    success: success,
                    at: location
                )
                if !transaction.hasCommittedLocation {
                    applyNavigationState(to: tab)
                }
                finishNavigationTransaction(for: tab, transaction: transaction)
            } else {
                updateCrashRecoveryStateAfterPageStop(
                    for: tab,
                    transaction: transaction,
                    success: false,
                    at: location
                )
                cancelNavigationTransaction(for: tab)
            }
        }
        
        tab.isLoading = false
        notifyUpdate(at: location.index, mode: location.mode, reason: .loading)
        notifyUpdate(at: location.index, mode: location.mode, reason: .navigationState)
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
