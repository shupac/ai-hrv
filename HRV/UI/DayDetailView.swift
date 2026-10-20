import SwiftUI

struct DayDetailView: View {
    @Environment(AppModel.self) private var model
    var day: String

    @State private var window: HRVWindow = .m5
    @State private var beats: [Beat]?
    @State private var points: [HRVPoint] = []
    @State private var selection: Date?
    @State private var editing: Tag?
    @State private var newTagTime: Date?
    @State private var motion: (frames: [MotionFrame], day: MotionDay, buckets: [MotionBucket], step: TimeInterval)?
    @State private var motionCSV: URL?
    @State private var motionLoading = false

    var body: some View {
        let tags = model.store.tags(on: day)
        List {
            Section {
                Picker("Window", selection: $window) {
                    ForEach(HRVWindow.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                HRVChart(points: points, tags: tags, showTagLabels: tags.count <= 12, selection: $selection)
                    .frame(height: 240)
                HRVChart(points: points, metric: .heartRate, tags: tags, showTagLabels: false)
                    .frame(height: 140)
                selectionRow
            } footer: {
                Text("Drag across the chart to pick a moment, then tag it.")
            }

            if let motion {
                motionSection(motion)
            } else if motionLoading {
                Section("Motion") { ProgressView() }
            }

            Section("Tags") {
                if tags.isEmpty {
                    Text("No tags yet").foregroundStyle(.secondary)
                }
                ForEach(tags) { t in
                    Button { editing = t } label: {
                        HStack {
                            Image(systemName: icon(t)).foregroundStyle(color(t))
                            Text(t.title).foregroundStyle(t.label == nil ? .secondary : .primary)
                            Spacer()
                            Text(t.time.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets { model.store.deleteTag(tags[i].id) }
                }
            }

            Section("Summary") {
                if let beats {
                    let valid = beats.filter(\.valid).count
                    let values = points.compactMap(\.rmssd)
                    LabeledContent("Recorded", value: formatDuration(beats.reduce(0) { $0 + $1.rr } / 1000))
                    LabeledContent("Artifacts", value: beats.isEmpty ? "—" :
                        "\(Int((Double(beats.count - valid) / Double(beats.count) * 100).rounded()))%")
                    LabeledContent("RMSSD median (\(window.label))",
                                   value: values.isEmpty ? "—" : "\(Int(ArtifactFilter.median(values).rounded())) ms")
                    LabeledContent("RMSSD range", value: values.isEmpty ? "—" :
                        "\(Int(values.min()!.rounded()))–\(Int(values.max()!.rounded())) ms")
                } else {
                    ProgressView()
                }
                ShareLink(item: model.store.csvURL(day: day)) {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(dayTitle(day))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { Task { await recompute(reload: true) } } label: { Image(systemName: "arrow.clockwise") }
        }
        .task(id: window) { await recompute(reload: false) }
        .sheet(item: $editing) { t in
            TagEditor(title: t.time.formatted(date: .omitted, time: .shortened), initial: t.label) { label in
                model.store.updateTag(t.id, label: label)
            }
        }
        .sheet(isPresented: Binding(get: { newTagTime != nil }, set: { if !$0 { newTagTime = nil } })) {
            if let time = newTagTime {
                TagEditor(title: time.formatted(date: .omitted, time: .shortened), initial: nil) { label in
                    if let label { model.tag(label, at: time) }
                }
            }
        }
    }

    private var domain: ClosedRange<Date> {
        let first = points.first?.time ?? motion?.buckets.first?.time
        let last = points.last?.time ?? motion?.buckets.last?.time
        guard let first, let last, first < last else { return Date().addingTimeInterval(-60)...Date() }
        return first...last
    }

    @ViewBuilder private func motionSection(
        _ m: (frames: [MotionFrame], day: MotionDay, buckets: [MotionBucket], step: TimeInterval)
    ) -> some View {
        Section {
            MotionChart(buckets: m.buckets, step: m.step, metric: .state, postureChanges: m.day.postureChanges,
                        domain: domain, selection: $selection)
                .frame(height: 70)
            MotionChart(buckets: m.buckets, step: m.step, metric: .movement, domain: domain, selection: $selection)
                .frame(height: 140)
            MotionChart(buckets: m.buckets, step: m.step, metric: .tilt, postureChanges: m.day.postureChanges,
                        domain: domain, selection: $selection)
                .frame(height: 140)
            if let selection {
                MotionDetail(frames: m.frames, seconds: m.day.seconds, around: selection)
            }
            if let motionCSV {
                ShareLink(item: motionCSV) { Label("Export motion signals", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("Motion")
        } footer: {
            Text("Lines mark posture changes.")
        }
    }

    @ViewBuilder private var selectionRow: some View {
        if let selection {
            let p = points.min { abs($0.time.timeIntervalSince(selection)) < abs($1.time.timeIntervalSince(selection)) }
            HStack {
                Text(selection.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                if let v = p?.rmssd { Text("· \(Int(v.rounded())) ms").foregroundStyle(.secondary) }
                if let hr = p?.meanHR { Text("· \(Int(hr.rounded())) bpm").foregroundStyle(.secondary) }
                Spacer()
                Button("Tag this moment") { newTagTime = selection }
                    .buttonStyle(.borderless)
            }
            .font(.subheadline)
        }
    }

    private func recompute(reload: Bool) async {
        let store = model.store
        if reload || beats == nil {
            let url = store.csvURL(day: day)
            store.flush()
            beats = await Task.detached(priority: .userInitiated) {
                DayStore.parseCSV((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }.value
        }
        if reload || motion == nil { await loadMotion() }
        let loaded = beats ?? []
        let window = window
        points = await Task.detached(priority: .userInitiated) { () -> [HRVPoint] in
            guard let first = loaded.first, let last = loaded.last else { return [] }
            // Keep a full day to ≈2000 chart points.
            let step = max(5, (last.time.timeIntervalSince(first.time) / 2000).rounded())
            return HRVCalculator.series(loaded, window: window, from: first.time, to: last.time, step: step)
        }.value
    }

    private func loadMotion() async {
        let recorder = model.store.motion
        let day = day
        recorder.flush()
        let url = recorder.url(day: day)
        motionLoading = FileManager.default.fileExists(atPath: url.path)
        defer { motionLoading = false }
        let result = await Task.detached(priority: .userInitiated) {
            () -> (frames: [MotionFrame], day: MotionDay, buckets: [MotionBucket], step: TimeInterval, csv: URL?)? in
            guard let data = try? Data(contentsOf: url), let frames = MotionFile.decode(data), !frames.isEmpty
            else { return nil }
            let analysis = MotionAnalysis.analyze(frames)
            guard let first = analysis.seconds.first?.time, let last = analysis.seconds.last?.time else { return nil }
            // Keep a full day to ≈700 buckets.
            let step = max(10, (last.timeIntervalSince(first) / 700 / 10).rounded(.up) * 10)
            let csv = FileManager.default.temporaryDirectory.appendingPathComponent("\(day)-motion.csv")
            let wrote = (try? analysis.csv().write(to: csv, atomically: true, encoding: .utf8)) != nil
            return (frames, analysis, analysis.buckets(step: step), step, wrote ? csv : nil)
        }.value
        motion = result.map { ($0.frames, $0.day, $0.buckets, $0.step) }
        motionCSV = result?.csv
    }

    private func icon(_ t: Tag) -> String {
        switch t.kind {
        case .manual: "tag"
        case .drop: "arrow.down.circle"
        case .rise: "arrow.up.circle"
        }
    }

    private func color(_ t: Tag) -> Color {
        switch t.kind {
        case .manual: .blue
        case .drop: .orange
        case .rise: .green
        }
    }
}

/// Pick a quick label or type one.
struct TagEditor: View {
    var title: String
    var initial: String?
    var onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("What was happening?", text: $text)
                        .onSubmit(save)
                }
                Section("Quick labels") {
                    ForEach(DayStore.quickLabels + ChangePrompter.quickReplies, id: \.self) { label in
                        Button(label) {
                            text = label
                            save()
                        }
                    }
                }
            }
            .navigationTitle("Tag \(title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear { text = initial ?? "" }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(t.isEmpty ? nil : t)
        dismiss()
    }
}
