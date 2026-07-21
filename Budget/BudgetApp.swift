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

/// Routes between the splash, sign-in, household onboarding, and the main app
/// based on session state.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if environment.isBootstrapping {
                SplashView()
            } else {
                switch environment.session.state {
                case .signedOut, .unknown:
                    SignInView()
                case .signedIn:
                    if environment.session.needsHousehold {
                        HouseholdSetupView()
                    } else {
                        RootTabView()
                    }
                }
            }
        }
        .task { await environment.bootstrap() }
    }
}

/// Shown briefly on launch while the session is refreshed from the server.
struct SplashView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            ProgressView()
        }
    }
}
