//
//  Tab.swift
//  Reynard
//
//  Created by Minh Ton on 5/3/26.
//

import GeckoView
import UIKit

enum ContentTerminationReason {
    case crash
    case kill
}

enum ContentTerminationState {
    case normal
    case crashed(url: String?, reason: ContentTerminationReason)
    case recovering(url: String?, reason: ContentTerminationReason)

    var crashedURL: String? {
        switch self {
        case let .crashed(url, _), let .recovering(url, _):
            return url
        case .normal:
            return nil
        }
    }

    var isCrashed: Bool {
        if case .crashed = self {
            return true
        }
        return false
    }

    var isRecovering: Bool {
        if case .recovering = self {
            return true
        }
        return false
    }
}

final class Tab {
    let id: UUID
    var session: GeckoSession
    var title: String
    var url: String?
    var isPrivate: Bool
    var favicon: UIImage?
    var pendingRestoreURL: String?
    var pendingDisplayText: String?
    var navigationTransaction: NavigationTransaction?
    var contentTerminationState: ContentTerminationState = .normal
    var isContentCrashed: Bool {
        get { contentTerminationState.isCrashed }
        set {
            if !newValue {
                contentTerminationState = .normal
            } else if !contentTerminationState.isCrashed {
                contentTerminationState = .crashed(url: url, reason: .crash)
            }
        }
    }
    var crashedURL: String? {
        get { contentTerminationState.crashedURL }
        set {
            switch contentTerminationState {
            case let .crashed(_, reason):
                contentTerminationState = .crashed(url: newValue, reason: reason)
            case let .recovering(_, reason):
                contentTerminationState = .recovering(url: newValue, reason: reason)
            case .normal:
                if let newValue {
                    contentTerminationState = .crashed(url: newValue, reason: .crash)
                }
            }
        }
    }
    var selectionOrder = 0
    var suppressInitialNavigation = true
    var sessionCanGoBack = false
    var sessionCanGoForward = false
    var canNavigateBack = false
    var canNavigateForward = false
    var isLoading = false
    var progress: Float = 0
    var thumbnail: UIImage?
    var nowPlayingController: NowPlayingController?
    
    init(
        id: UUID = UUID(),
        session: GeckoSession,
        title: String = "",
        url: String? = nil,
        favicon: UIImage? = nil,
        thumbnail: UIImage? = nil,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.session = session
        self.title = title
        self.url = url
        self.favicon = favicon
        self.thumbnail = thumbnail
        self.isPrivate = isPrivate
    }
}
