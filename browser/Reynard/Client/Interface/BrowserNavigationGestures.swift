//
//  BrowserNavigationGestures.swift
//  Reynard
//
//  Created by Codex on 8/6/26.
//

import UIKit

private enum BrowserNavigationGestureMetrics {
    static let fallbackActivationWidth: CGFloat = 24
    static let velocityFinishThreshold: CGFloat = 700

    static func isClearlyRightward(velocity: CGPoint) -> Bool {
        velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
    }

    static func clampedTranslationX(_ translationX: CGFloat, width: CGFloat) -> CGFloat {
        min(max(translationX, 0), max(width, 0))
    }

    static func finishThreshold(for width: CGFloat) -> CGFloat {
        max(80, width * 0.28)
    }

    static func shouldFinish(translationX: CGFloat, velocityX: CGFloat, width: CGFloat) -> Bool {
        translationX > finishThreshold(for: width) || velocityX > velocityFinishThreshold
    }
}

final class BrowserNavigationGestures: NSObject {
    private unowned let controller: BrowserViewController
    private let navigationHaptic = UIImpactFeedbackGenerator(style: .rigid)

    private weak var edgePanGesture: UIScreenEdgePanGestureRecognizer?
    private weak var fallbackPanGesture: UIPanGestureRecognizer?
    private var interactionStartLocation: CGPoint?
    private var isInteractionActive = false

    init(controller: BrowserViewController) {
        self.controller = controller
    }

    func configureGestures() {
        guard edgePanGesture == nil,
              fallbackPanGesture == nil else {
            return
        }

        let geckoView = controller.browserUI.geckoView
        geckoView.isUserInteractionEnabled = true

        let edgePan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleNavigationPan(_:)))
        edgePan.edges = .left
        edgePan.maximumNumberOfTouches = 1
        edgePan.delegate = self

        let fallbackPan = UIPanGestureRecognizer(target: self, action: #selector(handleNavigationPan(_:)))
        fallbackPan.maximumNumberOfTouches = 1
        fallbackPan.delegate = self
        fallbackPan.require(toFail: edgePan)

        geckoView.addGestureRecognizer(edgePan)
        geckoView.addGestureRecognizer(fallbackPan)

        edgePanGesture = edgePan
        fallbackPanGesture = fallbackPan
    }

    func resetInteraction() {
        controller.browserUI.geckoView.layer.removeAllAnimations()
        controller.browserUI.geckoView.transform = .identity
        interactionStartLocation = nil
        isInteractionActive = false
    }

    private var canStartNavigationGesture: Bool {
        guard controller.tabManager.selectedTab?.canNavigateBack == true,
              !controller.tabManager.selectedTabIsNavigatingHistory,
              !controller.isSearchFocused,
              !controller.isSearchScrollMode,
              !controller.tabOverviewPresentation.isVisible,
              !controller.tabOverviewPresentation.isTransitionRunning,
              !controller.isInFullscreenMedia else {
            return false
        }

        return true
    }

    @objc private func handleNavigationPan(_ recognizer: UIPanGestureRecognizer) {
        let geckoView = controller.browserUI.geckoView
        let translation = recognizer.translation(in: geckoView)
        let velocity = recognizer.velocity(in: geckoView)
        let width = geckoView.bounds.width

        switch recognizer.state {
        case .began:
            guard canStartNavigationGesture,
                  BrowserNavigationGestureMetrics.isClearlyRightward(velocity: velocity),
                  width > 1 else {
                resetInteraction()
                return
            }

            geckoView.layer.removeAllAnimations()
            geckoView.transform = .identity
            interactionStartLocation = recognizer.location(in: geckoView)
            isInteractionActive = true
            navigationHaptic.prepare()

        case .changed:
            guard isInteractionActive,
                  interactionStartLocation != nil else {
                return
            }

            guard canStartNavigationGesture else {
                animateCancellation()
                return
            }

            let translationX = BrowserNavigationGestureMetrics.clampedTranslationX(
                translation.x,
                width: width
            )
            geckoView.transform = CGAffineTransform(translationX: translationX, y: 0)

        case .ended:
            guard isInteractionActive,
                  interactionStartLocation != nil else {
                resetInteraction()
                return
            }

            let translationX = BrowserNavigationGestureMetrics.clampedTranslationX(
                translation.x,
                width: width
            )
            let shouldNavigateBack = BrowserNavigationGestureMetrics.shouldFinish(
                translationX: translationX,
                velocityX: velocity.x,
                width: width
            )

            if shouldNavigateBack {
                finishNavigation(width: width)
            } else {
                animateCancellation()
            }

        case .cancelled, .failed:
            animateCancellation()

        default:
            break
        }
    }

    private func finishNavigation(width: CGFloat) {
        isInteractionActive = false
        interactionStartLocation = nil
        navigationHaptic.impactOccurred()
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.controller.browserUI.geckoView.transform = CGAffineTransform(translationX: width, y: 0)
        } completion: { [weak self] finished in
            guard let self else {
                return
            }

            if finished {
                self.controller.goBack()
            }
            self.resetInteraction()
        }
    }

    private func animateCancellation() {
        isInteractionActive = false
        interactionStartLocation = nil
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.controller.browserUI.geckoView.transform = .identity
        } completion: { [weak self] _ in
            self?.resetInteraction()
        }
    }
}

extension BrowserNavigationGestures: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let fallbackPanGesture,
              gestureRecognizer === fallbackPanGesture else {
            return true
        }

        let location = touch.location(in: controller.browserUI.geckoView)
        return location.x <= BrowserNavigationGestureMetrics.fallbackActivationWidth
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard canStartNavigationGesture,
              let panGesture = gestureRecognizer as? UIPanGestureRecognizer else {
            return false
        }

        let velocity = panGesture.velocity(in: controller.browserUI.geckoView)
        return BrowserNavigationGestureMetrics.isClearlyRightward(velocity: velocity)
    }
}
