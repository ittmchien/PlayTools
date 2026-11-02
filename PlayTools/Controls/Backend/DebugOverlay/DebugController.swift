//
//  DebugController.swift
//  PlayTools
//
//  Created by 许沂聪 on 2024/5/28.
//

import Foundation

class DebugController {
    static let instance = DebugController()
    private init() {

    }

    private var debugView = DebugContainer.instance

    public func toggleDebugOverlay() {
        if debugView.superview == nil {
            // Skip showing the overlay when no key window/root view exists yet instead of crashing
            guard let view = screen.keyWindow?.rootViewController?.view else {
                return
            }
            view.addSubview(debugView)
            view.bringSubviewToFront(debugView)
            debugView.isHidden = false
            debugView.isUserInteractionEnabled = false
            PlayInput.touchQueue.async {
                DebugModel.instance.enabled = true
            }
        } else {
            debugView.removeFromSuperview()
            PlayInput.touchQueue.async {
                DebugModel.instance.enabled = false
            }
        }
    }
}
