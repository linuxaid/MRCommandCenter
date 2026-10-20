import SwiftData
import SwiftUI

/// Everything that happened across your MRs, newest first, grouped by day.
struct ActivityView: View {
    @Environment(AppModel.self) private var appModel
    @Query(sort: \ActivityEvent.date, order: .reverse) private var events: [ActivityEvent]
    @State private var onlyAutomation = false

    var body: some View {
        let shown = onlyAutomation ? events.filter { [.autoMerged, .autoMergeFailed, .autoMergeWouldMerge].contains($0.kind) } : events
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ACTIVITY").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
                    Text("What changed")
                        .font(Theme.headline(26))
                        .foregroundStyle(Theme.ink)
                    Picker("Show", selection: $onlyAutomation) {
                        Text("Everything").tag(false)
                        Text("Merge rules only").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.top, 4)
                }
                if days.isEmpty {
                    Text(onlyAutomation ? "No merge rule has acted yet." : "Nothing has changed yet. Changes appear here after each refresh.")
                        .foregroundStyle(Theme.inkTertiary)
                }
                ForEach(days, id: \.key) { day, dayEvents in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(dayTitle(day).uppercased())
                            .font(Theme.eyebrow)
                            .foregroundStyle(Theme.inkSecondary)
                        VStack(spacing: 0) {
                            ForEach(dayEvents) { event in
                                Button {
                                    select(event)
                                } label: {
                                    ActivityLine(event: event, showsMR: true)
                                        .padding(.horizontal, 14)
                                        .contentShape(.rect)
                                        .background(appModel.mergeRequests.selectedKey == event.mrKey ? Theme.sunken : .clear)
                                }
                                .buttonStyle(.plain)
                                .disabled(appModel.mergeRequests.mergeRequest(forKey: event.mrKey) == nil)
                                if event.id != dayEvents.last?.id { Divider().padding(.leading, 42) }
                            }
                        }
                        .card()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }

    private func select(_ event: ActivityEvent) {
        appModel.mergeRequests.selectedKey = event.mrKey
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}
