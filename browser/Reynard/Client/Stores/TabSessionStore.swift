//
//  TabSessionStore.swift
//  Reynard
//
//  Created by Minh Ton on 17/5/26.
//

import Foundation

final class TabSessionStore {
    static let shared = TabSessionStore()
    private static let maxHistoryEntries = 200
    
    enum ObservedNavigationIntent: Equatable {
        case back
        case forward
        case replace
        case normal
    }
    
    struct Snapshot {
        let currentURL: String?
        let backList: [String]
        let forwardList: [String]
        let ownsNav: Bool
        
        var canGoBack: Bool {
            !backList.isEmpty
        }
        
        var canGoForward: Bool {
            !forwardList.isEmpty
        }
    }
    
    private struct PersistedState: Codable {
        var currentURL: String?
        var backList: [String]
        var forwardList: [String]
        var ownsNav: Bool?
    }
    
    private let fileManager: FileManager
    private let directoryURL: URL
    private let stateQueue = DispatchQueue(label: "com.minh-ton.tab-session-store", qos: .userInitiated)
    private var cachedStates: [UUID: PersistedState] = [:]
    
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        
        guard let applicationSupportDirectoryURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory is unavailable")
        }
        
        self.directoryURL = applicationSupportDirectoryURL
            .appendingPathComponent("AppData", isDirectory: true)
            .appendingPathComponent("TabSessions", isDirectory: true)
        
        stateQueue.sync {
            prepareStorageLocked()
        }
    }
    
    func loadSnapshot(for tabID: UUID) -> Snapshot {
        stateQueue.sync {
            snapshot(from: stateLocked(for: tabID))
        }
    }
    
    func recordNavigation(to url: String, for tabID: UUID) -> Snapshot {
        recordObservedNavigation(to: url, for: tabID, intent: .normal)
    }
    
    func recordObservedNavigation(to url: String, for tabID: UUID, intent: ObservedNavigationIntent?) -> Snapshot {
        stateQueue.sync {
            var state = stateLocked(for: tabID)
            if state.currentURL == url {
                switch intent {
                case .back:
                    recordConfirmedBackNavigationLocked(to: url, state: &state)
                case .forward:
                    recordConfirmedForwardNavigationLocked(to: url, state: &state)
                default:
                    return snapshot(from: state)
                }
                saveStateLocked(state, for: tabID)
                return snapshot(from: state)
            }
            
            switch intent {
            case .back:
                recordConfirmedBackNavigationLocked(to: url, state: &state)
            case .forward:
                recordConfirmedForwardNavigationLocked(to: url, state: &state)
            case .replace:
                state.currentURL = url
            case .normal:
                recordNewNavigationLocked(to: url, state: &state)
            case nil:
                recordInferredNavigationLocked(to: url, state: &state)
            }
            
            saveStateLocked(state, for: tabID)
            return snapshot(from: state)
        }
    }
    
    func setOwnsNav(_ ownsNav: Bool, for tabID: UUID) -> Snapshot {
        stateQueue.sync {
            var state = stateLocked(for: tabID)
            state.ownsNav = ownsNav
            saveStateLocked(state, for: tabID)
            return snapshot(from: state)
        }
    }
    
    func previousURL(for tabID: UUID) -> String? {
        stateQueue.sync {
            var state = stateLocked(for: tabID)
            guard let targetURL = state.backList.popLast() else {
                return nil
            }
            
            if let currentURL = state.currentURL,
               !currentURL.isEmpty {
                state.forwardList.insert(currentURL, at: 0)
            }
            
            state.currentURL = targetURL
            saveStateLocked(state, for: tabID)
            return targetURL
        }
    }
    
    func nextURL(for tabID: UUID) -> String? {
        stateQueue.sync {
            var state = stateLocked(for: tabID)
            guard !state.forwardList.isEmpty else {
                return nil
            }
            
            let targetURL = state.forwardList.removeFirst()
            if let currentURL = state.currentURL,
               !currentURL.isEmpty {
                state.backList.append(currentURL)
            }
            
            state.currentURL = targetURL
            saveStateLocked(state, for: tabID)
            return targetURL
        }
    }
    
    func removeSession(for tabID: UUID) {
        stateQueue.async {
            self.cachedStates[tabID] = nil
            let fileURL = self.fileURL(for: tabID)
            guard self.fileManager.fileExists(atPath: fileURL.path) else {
                return
            }
            
            try? self.fileManager.removeItem(at: fileURL)
        }
    }
    
    private func prepareStorageLocked() {
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func stateLocked(for tabID: UUID) -> PersistedState {
        if let state = cachedStates[tabID] {
            return state
        }

        var state = loadPersistedStateLocked(for: tabID)
        trimHistoryLocked(&state)
        cachedStates[tabID] = state
        return state
    }
    
    private func recordNewNavigationLocked(to url: String, state: inout PersistedState) {
        if let currentURL = state.currentURL,
           !currentURL.isEmpty {
            state.backList.append(currentURL)
        }
        
        state.currentURL = url
        state.forwardList.removeAll(keepingCapacity: false)
    }
    
    private func recordInferredNavigationLocked(to url: String, state: inout PersistedState) {
        if state.backList.last == url {
            recordBackNavigationLocked(to: url, state: &state)
        } else if state.forwardList.first == url {
            recordForwardNavigationLocked(to: url, state: &state)
        } else {
            recordNewNavigationLocked(to: url, state: &state)
        }
    }
    
    private func recordConfirmedBackNavigationLocked(to url: String, state: inout PersistedState) {
        guard state.backList.last == url else {
            recordUnexpectedBackNavigationLocked(to: url, state: &state)
            return
        }
        
        recordBackNavigationLocked(to: url, state: &state)
    }
    
    private func recordConfirmedForwardNavigationLocked(to url: String, state: inout PersistedState) {
        guard state.forwardList.first == url else {
            recordUnexpectedForwardNavigationLocked(to: url, state: &state)
            return
        }
        
        recordForwardNavigationLocked(to: url, state: &state)
    }
    
    private func recordUnexpectedBackNavigationLocked(to url: String, state: inout PersistedState) {
        if !state.backList.isEmpty {
            _ = state.backList.popLast()
        }

        state.backList.removeAll { $0 == url }
        state.forwardList.removeAll { $0 == url }
        
        if let currentURL = state.currentURL,
           !currentURL.isEmpty,
           currentURL != url {
            state.forwardList.insert(currentURL, at: 0)
        }

        state.currentURL = url
    }

    private func recordUnexpectedForwardNavigationLocked(to url: String, state: inout PersistedState) {
        if !state.forwardList.isEmpty {
            _ = state.forwardList.removeFirst()
        }

        state.backList.removeAll { $0 == url }
        state.forwardList.removeAll { $0 == url }

        if let currentURL = state.currentURL,
           !currentURL.isEmpty,
           currentURL != url {
            state.backList.append(currentURL)
        }

        state.currentURL = url
    }

    private func recordBackNavigationLocked(to url: String, state: inout PersistedState) {
        if !state.backList.isEmpty {
            _ = state.backList.popLast()
        }
        
        if let currentURL = state.currentURL,
           !currentURL.isEmpty,
           currentURL != url {
            state.forwardList.insert(currentURL, at: 0)
        }
        
        state.currentURL = url
    }
    
    private func recordForwardNavigationLocked(to url: String, state: inout PersistedState) {
        if !state.forwardList.isEmpty {
            _ = state.forwardList.removeFirst()
        }
        
        if let currentURL = state.currentURL,
           !currentURL.isEmpty,
           currentURL != url {
            state.backList.append(currentURL)
        }
        
        state.currentURL = url
    }
    
    private func loadPersistedStateLocked(for tabID: UUID) -> PersistedState {
        guard let data = try? Data(contentsOf: fileURL(for: tabID)),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return PersistedState(currentURL: nil, backList: [], forwardList: [], ownsNav: nil)
        }
        
        return decoded
    }
    
    private func saveStateLocked(_ state: PersistedState, for tabID: UUID) {
        var state = state
        trimHistoryLocked(&state)
        cachedStates[tabID] = state
        savePersistedStateLocked(state, for: tabID)
    }

    private func savePersistedStateLocked(_ state: PersistedState, for tabID: UUID) {
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        
        try? data.write(to: fileURL(for: tabID), options: .atomic)
    }

    private func trimHistoryLocked(_ state: inout PersistedState) {
        if state.backList.count > Self.maxHistoryEntries {
            state.backList.removeFirst(state.backList.count - Self.maxHistoryEntries)
        }

        if state.forwardList.count > Self.maxHistoryEntries {
            state.forwardList.removeLast(state.forwardList.count - Self.maxHistoryEntries)
        }
    }
    
    private func snapshot(from state: PersistedState) -> Snapshot {
        Snapshot(
            currentURL: state.currentURL,
            backList: state.backList,
            forwardList: state.forwardList,
            ownsNav: state.ownsNav ?? false
        )
    }
    
    private func fileURL(for tabID: UUID) -> URL {
        directoryURL.appendingPathComponent(tabID.uuidString, isDirectory: false)
    }
}
