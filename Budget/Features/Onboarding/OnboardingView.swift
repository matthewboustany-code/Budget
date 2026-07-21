import SwiftUI

/// Placeholder for the P1 onboarding flow: Sign in with Apple, then create or
/// join a household, then link the first account with Plaid. Not shown in P0
/// (RootView goes straight to the tab shell) but the file exists so P1 has a
/// home for the flow.
struct OnboardingView: View {
    var body: some View {
        PlaceholderScreen(icon: "person.2.fill",
                          title: "Welcome to Budget",
                          phase: "Phase 1")
    }
}
