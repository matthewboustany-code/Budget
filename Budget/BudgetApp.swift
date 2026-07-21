//
//  BudgetApp.swift
//  Budget
//
//  Created by Hannah Purvis on 7/21/26.
//

import SwiftUI

@main
struct BudgetApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
    }
}

/// Routes between onboarding and the main app based on session state. For P0,
/// auth isn't wired yet, so the main tab shell is always shown; P1 flips this
/// on `session.state`.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        RootTabView()
            .task { await environment.checkConnection() }
    }
}
