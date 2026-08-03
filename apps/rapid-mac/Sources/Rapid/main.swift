import AppKit
import Foundation
import SwiftUI

// Entry point. Hand off to SwiftUI's App protocol.
//
// We use an explicit `main.swift` (rather than `@main` on `RapidApp`)
// so the AppKit menu-bar host can be installed from the app delegate
// before SwiftUI takes over the event loop.

RapidApp.main()
