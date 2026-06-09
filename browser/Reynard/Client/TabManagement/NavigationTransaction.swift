//
//  NavigationTransaction.swift
//  Reynard
//
//  Created by Codex on 9/6/26.
//

import Foundation
import GeckoView

final class NavigationTransaction {
    enum Direction {
        case back
        case forward
    }

    enum Kind {
        case normal
        case replace
        case sessionHistory(Direction)
        case applicationHistory(Direction)
    }

    enum Phase {
        case created
        case loadRequested
        case pageStarted
        case locationObserved
        case committed
        case stopped
        case cancelled
    }

    enum Source {
        case userNavigation
        case geckoLoadRequest
        case websiteModeChange
        case historyButton
        case historyGesture
        case restoredAppHistory
        case crashRecovery
    }

    let id: UUID
    let kind: Kind
    let startedURL: String?
    let expectedURL: String?
    let usesReplaceHistory: Bool
    let source: Source
    let startedCanGoBack: Bool
    let startedCanGoForward: Bool
    weak var session: GeckoSession?
    var requestedURL: String?
    var observedURL: String?
    var lastObservedURL: String?
    var lastLoadRequestURL: String?
    var lastTriggerURL: String?
    var phase: Phase
    var watchdogTask: Task<Void, Never>?
    var hasCommittedLocation: Bool
    var hasObservedRedirectRequest: Bool
    var lastLoadRequestWasRedirect: Bool
    var hasUserGesture: Bool
    var isDirectNavigation: Bool
    var recoveryTargetURL: String?
    var hasObservedRecoveryTarget: Bool
    var commitCount: Int

    init(
        id: UUID = UUID(),
        kind: Kind,
        startedURL: String?,
        requestedURL: String?,
        expectedURL: String?,
        session: GeckoSession,
        usesReplaceHistory: Bool,
        source: Source,
        startedCanGoBack: Bool,
        startedCanGoForward: Bool
    ) {
        self.id = id
        self.kind = kind
        self.startedURL = startedURL
        self.requestedURL = requestedURL
        self.expectedURL = expectedURL
        self.session = session
        self.usesReplaceHistory = usesReplaceHistory
        self.source = source
        self.startedCanGoBack = startedCanGoBack
        self.startedCanGoForward = startedCanGoForward
        phase = .created
        hasCommittedLocation = false
        hasObservedRedirectRequest = false
        lastLoadRequestWasRedirect = false
        hasUserGesture = false
        isDirectNavigation = false
        switch source {
        case .crashRecovery:
            recoveryTargetURL = requestedURL
        case .userNavigation, .geckoLoadRequest, .websiteModeChange, .historyButton, .historyGesture, .restoredAppHistory:
            recoveryTargetURL = nil
        }
        hasObservedRecoveryTarget = false
        commitCount = 0
    }

    func recordLoadRequest(
        uri: String,
        triggerUri: String?,
        isRedirect: Bool,
        hasUserGesture: Bool,
        isDirectNavigation: Bool
    ) {
        lastLoadRequestURL = uri
        lastTriggerURL = triggerUri
        lastLoadRequestWasRedirect = isRedirect
        hasObservedRedirectRequest = hasObservedRedirectRequest || isRedirect
        self.hasUserGesture = hasUserGesture
        self.isDirectNavigation = isDirectNavigation
        requestedURL = uri
    }

    func recordLocationCommit(_ url: String) {
        observedURL = url
        lastObservedURL = url
        hasCommittedLocation = true
        commitCount += 1
        if normalizedURL(url) == normalizedURL(recoveryTargetURL) {
            hasObservedRecoveryTarget = true
        }
    }

    var isHistoryNavigation: Bool {
        switch kind {
        case .sessionHistory, .applicationHistory:
            return true
        case .normal, .replace:
            return false
        }
    }

    var isPendingHistoryNavigation: Bool {
        guard isHistoryNavigation else {
            return false
        }

        switch phase {
        case .created, .loadRequested, .pageStarted, .locationObserved:
            return true
        case .committed, .stopped, .cancelled:
            return false
        }
    }

    var isTerminal: Bool {
        switch phase {
        case .committed, .stopped, .cancelled:
            return true
        case .created, .loadRequested, .pageStarted, .locationObserved:
            return false
        }
    }

    var canAcceptPageStart: Bool {
        !isTerminal
    }

    var shouldTreatAdditionalLocationAsRedirectFinalization: Bool {
        hasCommittedLocation && (hasObservedRedirectRequest || lastLoadRequestWasRedirect)
    }

    var hasSatisfiedRecoveryTarget: Bool {
        hasObservedRecoveryTarget || (hasCommittedLocation && hasObservedRedirectRequest)
    }

    private func normalizedURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return value
    }
}
