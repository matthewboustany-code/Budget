import SwiftUI

/// Reusable "this feature is coming" scaffold, used by every P0 feature screen
/// so the navigation shell is complete and each phase can replace one screen
/// at a time.
struct PlaceholderScreen: View {
    let icon: String
    let title: String
    let phase: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text("Arriving in \(phase).")
        }
    }
}
