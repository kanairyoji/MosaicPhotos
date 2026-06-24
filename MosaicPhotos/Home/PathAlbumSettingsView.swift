import AutoAlbumCore
import SwiftUI

/// フォルダ名アルバム（Dropbox パスから推測）の設定画面。
/// 有効化トグル・正規表現ルールの編集・ライブプレビューを提供する。ルールは JSON で永続化。
struct PathAlbumSettingsView: View {
    let engine: AutoAlbumEngine?

    @AppStorage(AutoAlbumSettingsKeys.pathAlbumsEnabled) private var enabled = false
    @AppStorage(AutoAlbumSettingsKeys.pathAlbumRules)     private var rulesJSON = ""

    @State private var rules: [PathAlbumRule] = []
    @State private var samplePath = ""

    /// 初期セットとして提示する例（任意で挿入）。
    private static let examples: [PathAlbumRule] = [
        PathAlbumRule(pattern: "^/Trips/(?<name>[^/]+)/", template: "${name}"),
        PathAlbumRule(pattern: "^/(?:Photos|Pictures)/(?:\\d{4}[-_]\\d{2}\\s+)?(?<name>[^/]+)/[^/]+$", template: "${name}"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Enable folder-name albums", isOn: $enabled)
                Text("Infer album names from the Dropbox folder each photo lives in, using the rules below. Paths that match no rule are ignored, so junk folders (e.g. Camera Uploads) are skipped. Off by default.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Rules (first match wins)") {
                if rules.isEmpty {
                    Text("No rules yet.").foregroundStyle(.secondary)
                }
                ForEach(rules.indices, id: \.self) { index in
                    ruleEditor(index)
                }
                .onDelete { rules.remove(atOffsets: $0) }

                Button { rules.append(PathAlbumRule(pattern: "", template: "${name}")) } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                if rules.isEmpty {
                    Button { rules = Self.examples } label: {
                        Label("Insert Examples", systemImage: "sparkles")
                    }
                }
            }

            Section("Preview") {
                TextField("Paste a sample path…", text: $samplePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(previewText)
                    .font(.callout)
                    .foregroundStyle(previewMatched ? .primary : .secondary)
            }

            Section {
                LabeledContent("Folder albums", value: "\(engine?.pathAlbums.count ?? 0)")
                Button {
                    Task { await engine?.generatePathAlbums() }
                } label: {
                    if engine?.isGeneratingPath == true {
                        HStack { ProgressView().controlSize(.small); Text("Regenerating…") }
                    } else {
                        Text("Regenerate Albums")
                    }
                }
                .disabled(engine == nil || engine?.isGeneratingPath == true || !enabled)
                Text("Albums appear in the “Albums” section on the home screen. They are built from Dropbox photos only, so connect Dropbox and load Cloud first. Runs in the background — regenerate after changing rules.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Folder Albums")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: decodeRules)
        .onChange(of: rules) { _, _ in encodeRules() }
        // 有効化したら自動で1回（軽量・バックグラウンド）再生成し、ホームの「Albums」に反映する。
        .onChange(of: enabled) { _, isOn in
            if isOn { Task { await engine?.generatePathAlbums() } }
        }
    }

    // MARK: - Rule editor row

    @ViewBuilder
    private func ruleEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Regex pattern", text: $rules[index].pattern, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Name template (e.g. ${name})", text: $rules[index].template)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Ignore case", isOn: $rules[index].caseInsensitive)
                .font(.caption)
            if !rules[index].pattern.isEmpty, !PathAlbumNamer.isValidPattern(rules[index].pattern) {
                Label("Invalid regular expression", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Preview

    private var previewMatched: Bool {
        !samplePath.isEmpty && PathAlbumNamer.preview(path: samplePath, rules: rules) != nil
    }

    private var previewText: String {
        guard !samplePath.isEmpty else { return "Enter a path to test your rules." }
        guard let result = PathAlbumNamer.preview(path: samplePath, rules: rules) else {
            return "No match — this path would be ignored."
        }
        return "Rule #\(result.index + 1) → “\(result.name)”"
    }

    // MARK: - Persistence

    private func decodeRules() {
        guard let data = rulesJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([PathAlbumRule].self, from: data)
        else { return }
        rules = decoded
    }

    private func encodeRules() {
        guard let data = try? JSONEncoder().encode(rules),
              let json = String(data: data, encoding: .utf8) else { return }
        rulesJSON = json
    }
}
