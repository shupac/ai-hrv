import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.store.days, id: \.self) { day in
                    NavigationLink(value: day) {
                        DayRow(day: day, summary: model.store.summaries[day], tagCount: model.store.tags(on: day).count)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { model.store.deleteDay(model.store.days[i]) }
                }
            }
            .overlay {
                if model.store.days.isEmpty {
                    ContentUnavailableView("No data yet", systemImage: "waveform.path.ecg",
                                           description: Text("Everything is recorded automatically while the strap is connected."))
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: String.self) { DayDetailView(day: $0) }
            .task { await model.store.refreshSummaries() }
            .refreshable { await model.store.refreshSummaries() }
        }
    }
}

struct DayRow: View {
    var day: String
    var summary: DaySummary?
    var tagCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dayTitle(day)).font(.headline)
            HStack(spacing: 12) {
                if let s = summary {
                    Text(formatDuration(s.recordedSeconds) + " recorded")
                    if let h = s.medianRMSSD { Text("RMSSD \(Int(h.rounded())) ms") }
                    if let hr = s.meanHR { Text("\(Int(hr.rounded())) bpm") }
                } else {
                    Text("Calculating…")
                }
                if tagCount > 0 { Label("\(tagCount)", systemImage: "tag") }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }
}

func dayTitle(_ day: String) -> String {
    guard let date = DayKey.date(day) else { return day }
    if Calendar.current.isDateInToday(date) { return "Today" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.weekday(.wide).month().day())
}

func formatDuration(_ t: TimeInterval) -> String {
    Duration.seconds(t).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
}
