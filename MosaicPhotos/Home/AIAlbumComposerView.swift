import AutoAlbumCore
import SwiftUI

/// 自然文で AI アルバムを作るシート。端末内（Foundation Models またはルールベース）で解釈し、
/// 付加情報を検索してアルバム化する。通信なし。
struct AIAlbumComposerView: View {
    let engine: AutoAlbumEngine
    /// 編集対象（再設定）。nil なら新規作成。
    var editing: AutoAlbumInfo?
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var criteria: String

    private var isEditing: Bool { editing != nil }

    init(engine: AutoAlbumEngine, editing: AutoAlbumInfo? = nil) {
        self.engine = engine
        self.editing = editing
        // 編集対象の値で確実に初期化する（onAppear 依存だと再利用時に取りこぼす）。
        _title = State(initialValue: editing?.title ?? "")
        _criteria = State(initialValue: editing?.criteria ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Album name (optional)", text: $title)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("e.g. Okinawa trips in recent years / favorites with Mom", text: $criteria, axis: .vertical)
                        .lineLimit(1...4)
                        .autocorrectionDisabled()
                } header: {
                    Text("Photos to include")
                } footer: {
                    Text("Searches your photos on-device by place, date, people and favorites. No network used.")
                }

                // 動作タイミングの説明（プレビュー→夜間本番化の2段階を明示。
                // 「作らないと勘違い」を防ぐため、いつ増える/良くなるかを書く）。
                Section {
                } footer: {
                    Label {
                        Text("You'll see a quick preview right away. The album is then fully analyzed and refined while your iPhone is locked, charging, and connected to Wi-Fi (typically overnight) — results improve automatically as photos are indexed.")
                    } icon: {
                        Image(systemName: "moon.zzz")
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        Text(isEditing ? L("Update Album") : L("Create Album"))
                    }
                    .disabled(criteria.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle(isEditing ? L("Edit AI Album") : L("AI Album"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        // 検索は数万件の走査で数秒かかり得るため、**この場では待たない**。
        // 実処理はバックグラウンドで進め（engine が保持・シートより長生き）、シートは即閉じる。
        // ⚠️ 待たせるとタップが「固まった」ように見える（実障害）。0 件でも保存され、
        // 取り込みが進むと背景で自動的に埋まる。進捗は AI アルバムのヘッダーのスピナーで示す。
        engine.beginMakeAIAlbum(id: editing?.id, title: title, criteria: criteria)
        dismiss()
    }
}
