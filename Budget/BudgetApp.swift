//
//  BudgetApp.swift
//  Budget
//
//  Created by Hannah Purvis on 7/21/26.
//

import SwiftUI
import UIKit

@main
struct BudgetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
    }
}

/// SwiftUI has no scene-level hook for the APNs token callbacks, so this
/// minimal delegate exists solely to forward them. It republishes the token as
/// a notification rather than reaching for the environment, which keeps the
/// delegate free of app state and lets `PushRegistrar` stay injectable.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: PushRegistrar.didReceiveTokenNotification,
                                        object: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected on the Simulator and when the device is offline. Reminders
        // are a convenience; the next launch retries.
        print("APNs registration failed: \(error.localizedDescription)")
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
