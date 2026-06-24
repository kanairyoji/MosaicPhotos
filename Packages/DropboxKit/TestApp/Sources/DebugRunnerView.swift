import DropboxKit
import SwiftUI

struct DebugRunnerView: View {
    let dropboxAuth: DropboxAuthService
    @Binding var useTabView: Bool

    @State private var runner = DebugRunner()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    actionsSection
                    logSection
                }
                .onChange(of: runner.entries.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo(runner.entries.last?.id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("Debug Runner")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { runner.clear() }
                        .disabled(runner.entries.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        useTabView.toggle()
                    } label: {
                        Image(systemName: useTabView ? "list.bullet" : "square.split.2x1")
                    }
                }
            }
        }
    }

    // MARK: - Actions section

    private var actionsSection: some View {
        Section("Actions") {
            stepButton("Check Status") {
                runner.checkStatus(auth: dropboxAuth)
            }
            asyncStepButton("Fresh Token") {
                await runner.freshToken(auth: dropboxAuth)
            }
            asyncStepButton("Load Items") {
                await runner.loadItems(auth: dropboxAuth)
            }
            stepButton("List Items") {
                runner.listItems()
            }
            asyncStepButton("Get Thumbnail") {
                await runner.getThumbnail()
            }
            asyncStepButton("Get Full Image") {
                await runner.getFullImage()
            }
            asyncStepButton("Run All", role: .none, tint: .blue) {
                await runner.runAll(auth: dropboxAuth)
            }
        }
    }

    @ViewBuilder
    private func stepButton(
        _ label: String,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role) {
            action()
        } label: {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(tint)
        .disabled(runner.isRunning)
    }

    @ViewBuilder
    private func asyncStepButton(
        _ label: String,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        action: @escaping () async -> Void
    ) -> some View {
        Button(role: role) {
            Task { await action() }
        } label: {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(tint)
        .disabled(runner.isRunning)
    }

    // MARK: - Log section

    private var logSection: some View {
        Section("Log") {
            if runner.entries.isEmpty {
                Text("No output yet. Tap an action above.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(runner.entries) { entry in
                    logRow(entry)
                        .id(entry.id)
                }
            }
        }
    }

    private func logRow(_ entry: DebugRunner.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.timestamp.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                    .foregroundStyle(.tertiary)
                Text("[\(entry.step)]")
                    .foregroundStyle(.secondary)
            }
            .font(.system(.caption2, design: .monospaced))
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entry.isError ? Color.red : Color.primary)
        }
        .listRowBackground(Color.clear)
    }

}
