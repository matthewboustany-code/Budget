import SwiftUI
import WidgetKit
import BudgetModels

@main
struct BudgetWidgetBundle: WidgetBundle {
    var body: some Widget {
        BudgetLeftWidget()
        NextBillWidget()
    }
}

// MARK: - Shared timeline

/// Both widgets read the same snapshot the app publishes into the App Group,
/// so the extension makes no network call and holds no session token.
struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?

    static let placeholder = SnapshotEntry(date: .now, snapshot: WidgetSnapshot(
        generatedAt: .now, budgetedLimit: 2400, budgetedSpent: 1712, monthLabel: "September",
        nextBillName: "Internet", nextBillAmount: 84, nextBillDueDate: .now.addingTimeInterval(3 * 86_400)))
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? .placeholder : SnapshotEntry(date: .now, snapshot: WidgetSnapshotReader.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshotReader.read())
        // One entry, refreshed after an hour: nothing here changes on its own
        // (unlike a countdown), so extra entries would render the same numbers.
        // The app also reloads timelines the moment the numbers actually move,
        // which is what keeps this current between refreshes.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

enum WidgetSnapshotReader {
    static func read() -> WidgetSnapshot? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetSharing.appGroupID),
              let data = try? Data(contentsOf: container.appendingPathComponent(WidgetSharing.snapshotFileName))
        else { return nil }
        return try? WidgetSharing.decoder().decode(WidgetSnapshot.self, from: data)
    }
}

// MARK: - Budget left this month

struct BudgetLeftWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BudgetLeft", provider: SnapshotProvider()) { entry in
            BudgetLeftView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Budget left")
        .description("What's left of this month's budgeted categories.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular])
    }
}

private struct BudgetLeftView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot, snapshot.hasBudget {
            switch family {
            case .accessoryCircular:
                Gauge(value: snapshot.spentFraction) {
                    Image(systemName: "chart.pie.fill")
                } currentValueLabel: {
                    Text(compact(snapshot.remaining))
                }
                .gaugeStyle(.accessoryCircular)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("Budget left").font(.caption).foregroundStyle(.secondary)
                    Text(currency(snapshot.remaining)).font(.headline)
                    ProgressView(value: snapshot.spentFraction).progressViewStyle(.linear)
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.monthLabel).font(.caption).foregroundStyle(.secondary)
                    Text(currency(snapshot.remaining))
                        .font(.system(.title2, design: .rounded).bold())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .foregroundStyle(snapshot.remaining < 0 ? .red : .primary)
                    Text(snapshot.remaining < 0 ? "over budget" : "left to spend")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    ProgressView(value: snapshot.spentFraction)
                        .tint(snapshot.remaining < 0 ? .red : .green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            WidgetEmptyState(
                icon: "chart.pie",
                message: entry.snapshot == nil ? "Open Budget" : "No budgets set",
                family: family)
        }
    }
}

// MARK: - Next bill

struct NextBillWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextBill", provider: SnapshotProvider()) { entry in
            NextBillView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next bill")
        .description("The soonest bill you still owe.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

private struct NextBillView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot, let name = snapshot.nextBillName,
           let amount = snapshot.nextBillAmount, let due = snapshot.nextBillDueDate {
            let dueColor: Color = snapshot.nextBillIsOverdue ? .red : .secondary
            if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.caption).lineLimit(1)
                    Text(currency(amount)).font(.headline)
                    // Relative, not absolute: "in 3 days" is the thing you act
                    // on, and it stays right as the timeline entry ages.
                    Text(due, format: .relative(presentation: .numeric)).font(.caption2)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Next bill", systemImage: "calendar")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(currency(amount))
                        .font(.system(.title3, design: .rounded).bold())
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(snapshot.nextBillIsOverdue
                         ? "overdue"
                         : due.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(dueColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            WidgetEmptyState(
                icon: "calendar",
                message: entry.snapshot == nil ? "Open Budget" : "Nothing due",
                family: family)
        }
    }
}

// MARK: - Shared bits

/// Two distinct empty states on purpose: "Open Budget" means the app has never
/// published a snapshot (fresh install, or signed out), while the other means
/// the data arrived and there genuinely is nothing to show.
private struct WidgetEmptyState: View {
    let icon: String
    let message: String
    let family: WidgetFamily

    var body: some View {
        if family == .accessoryCircular {
            Image(systemName: icon)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func currency(_ amount: Money) -> String {
    amount.formatted(.currency(code: "USD").precision(.fractionLength(0)))
}

/// Lock Screen circular has room for about four glyphs — "$1.2K", not "$1,240".
private func compact(_ amount: Money) -> String {
    let value = (amount as NSDecimalNumber).doubleValue
    if abs(value) >= 1000 {
        return String(format: "%@$%.1fK", value < 0 ? "-" : "", abs(value) / 1000)
    }
    return String(format: "%@$%.0f", value < 0 ? "-" : "", abs(value))
}
