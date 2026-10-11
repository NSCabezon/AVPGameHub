import AppKit
import HubCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A growing log fed from background threads, published to the UI in batches.
@MainActor @Observable
final class LogStore {
    struct Line: Identifiable, Hashable {
        let id: Int
        let text: String
    }

    private(set) var lines: [Line] = []
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored let limit: Int
    @ObservationIgnored private let pending = PendingLines()
    /// Called on the main actor with each batch (stats/step parsing).
    @ObservationIgnored var onLines: (([String]) -> Void)?

    init(limit: Int = 40_000) { self.limit = limit }

    func clear() {
        lines = []
        _ = pending.take()
    }

    func append(_ text: String) { add([text]) }

    /// A thread-safe sink for ProcessRunner.
    nonisolated func sink() -> @Sendable (String) -> Void {
        let p = pending
        return { [weak self] line in
            if p.add(line) {
                Task { @MainActor in self?.drain() }
            }
        }
    }

    private func drain() {
        let batch = pending.take()
        if !batch.isEmpty { add(batch) }
    }

    private func add(_ batch: [String]) {
        var new = lines
        let secrets = Privacy.secrets
        for t in batch {
            new.append(Line(id: nextID, text: secrets.isEmpty ? t : Privacy.redact(t, secrets: secrets)))
            nextID += 1
        }
        if new.count > limit { new.removeFirst(new.count - limit) }
        lines = new
        onLines?(batch)
    }

    var text: String { lines.map(\.text).joined(separator: "\n") }
}

final class PendingLines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var scheduled = false

    /// True when the caller must schedule a drain.
    func add(_ s: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        items.append(s)
        if scheduled { return false }
        scheduled = true
        return true
    }

    func take() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = items
        items = []
        scheduled = false
        return out
    }
}

/// Monospaced, filterable, auto-following log view.
struct LogConsoleView: View {
    let store: LogStore
    var showFilters = true
    @State private var category: LogCategory = .all
    @State private var search = ""
    @State private var follow = true
    private let shown = 4000

    var body: some View {
        let filtered = store.lines.filter { LogFilter.matches($0.text, category: category, search: search) }
        let visible = filtered.suffix(shown)
        VStack(spacing: 6) {
            HStack {
                if showFilters {
                    Picker("", selection: $category) {
                        ForEach(LogCategory.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 380)
                    TextField(L("Buscar", "Search"), text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                Spacer()
                Toggle(L("Seguir", "Follow"), isOn: $follow).toggleStyle(.checkbox)
                Text("\(filtered.count) / \(store.lines.count)").foregroundStyle(.secondary).monospacedDigit()
                Button { copyAll() } label: { Image(systemName: "doc.on.doc") }.help(L("Copiar log", "Copy log"))
                Button { save() } label: { Image(systemName: "square.and.arrow.down") }.help(L("Guardar log…", "Save log…"))
                Button { store.clear() } label: { Image(systemName: "trash") }.help(L("Vaciar", "Clear"))
            }
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line.text))
                                .fixedSize(horizontal: true, vertical: false)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: store.lines.last?.id) { _, _ in
                    if follow, let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func color(for line: String) -> Color {
        if BuildLog.isError(line) { return .red }
        if line.contains("[perf]") || line.contains("[mvk-fov]") { return .blue }
        if line.contains("[session]") { return .green }
        if BuildLog.step(in: line) != nil { return .orange }
        return .primary
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.text, forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "avpgamehub-\(Int(Date().timeIntervalSince1970)).log"
        panel.allowedContentTypes = [.plainText, .log]
        if panel.runModal() == .OK, let url = panel.url {
            try? store.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
