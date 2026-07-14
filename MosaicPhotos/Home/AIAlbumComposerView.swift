import AutoAlbumCore
import SwiftUI

/// 自然文で AI アルバムを作るシート。端末内（Foundation Models またはルールベース）で解釈し、
/// 付加情報を検索してアルバム化する。通信なし。
///
/// 入力支援（ADR-37）:
/// - サジェストチップ: ライブラリから観測された語（人物/場所/よく写るもの/日付の定型）を
///   タップで挿入。**確実にヒットする語だけ**を出す（人物=命名済みクラスタ・場所=カタログ実在・
///   視覚語=頻出タグ∩レキシコン・日付=パーサ対応の定型）。
/// - 接地プレビュー: 入力がどう解釈されるかを色付きチップで表示（本番と同じ決定的レイヤーの流用）
///   ＋ハード条件のヒット件数。
struct AIAlbumComposerView: View {
    let engine: AutoAlbumEngine
    /// 編集対象（再設定）。nil なら新規作成。
    var editing: AutoAlbumInfo?
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var criteria: String
    @State private var suggestions = AIAlbumSuggestions()
    @State private var preview = AIAlbumGroundingPreview()
    /// 接地プレビューの debounce 用（タイプごとに前回タスクをキャンセル）。
    @State private var previewTask: Task<Void, Never>?

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
                    if !preview.chips.isEmpty || preview.hardHitCount != nil {
                        groundingRow
                    }
                } header: {
                    Text("Photos to include")
                } footer: {
                    Text("Searches your photos on-device by place, date, people and favorites. No network used.")
                }

                if !suggestions.isEmpty {
                    suggestionSection
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
        .task {
            // CLIP テキストタワーを入力中に温める（未ロードだと「作成」タップ後に初回ロードが乗る）。
            engine.prepareAIComposer()
            suggestions = await engine.albumSuggestions()
            // 編集時は既存の検索文の接地プレビューを即時に出す。
            refreshPreview(debounce: false)
        }
        .onChange(of: criteria) { _, _ in refreshPreview(debounce: true) }
    }

    // MARK: - 接地プレビュー（入力の解釈のされ方＋ヒット件数）

    private func refreshPreview(debounce: Bool) {
        previewTask?.cancel()
        let text = criteria
        previewTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            let result = await engine.groundingPreview(criteria: text)
            guard !Task.isCancelled, text == criteria else { return }
            preview = result
        }
    }

    @ViewBuilder
    private var groundingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !preview.chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text(L("Interpreted:"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(preview.chips) { chip in
                            chipView(chip)
                        }
                    }
                }
            }
            if let count = preview.hardHitCount {
                Text(L("Matches filters: \(count) photos"))
                    .font(.caption)
                    .foregroundStyle(count == 0 ? Color.orange : Color.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func chipView(_ chip: AIAlbumGroundingPreview.Chip) -> some View {
        HStack(spacing: 3) {
            Image(systemName: chipIcon(chip.kind))
                .font(.system(size: 9))
            Text(chip.text)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(chipColor(chip.kind).opacity(0.15), in: Capsule())
        .foregroundStyle(chipColor(chip.kind))
    }

    private func chipIcon(_ kind: AIAlbumGroundingPreview.Chip.Kind) -> String {
        switch kind {
        case .person: return "person.fill"
        case .place:  return "mappin"
        case .visual: return "tag.fill"
        case .date:   return "calendar"
        }
    }

    private func chipColor(_ kind: AIAlbumGroundingPreview.Chip.Kind) -> Color {
        switch kind {
        case .person: return .pink
        case .place:  return .green
        case .visual: return .blue
        case .date:   return .orange
        }
    }

    // MARK: - サジェストチップ（タップで挿入）

    @ViewBuilder
    private var suggestionSection: some View {
        Section {
            if !suggestions.people.isEmpty {
                suggestionRow(icon: "person.fill", color: .pink, words: suggestions.people)
            }
            if !suggestions.places.isEmpty {
                suggestionRow(icon: "mappin", color: .green, words: suggestions.places)
            }
            if !suggestions.visualWords.isEmpty {
                suggestionRow(icon: "tag.fill", color: .blue, words: suggestions.visualWords)
            }
            if !suggestions.dateWords.isEmpty {
                suggestionRow(icon: "calendar", color: .orange, words: suggestions.dateWords)
            }
        } header: {
            Text("Tap to add — from your library")
        }
    }

    private func suggestionRow(icon: String, color: Color, words: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                ForEach(words, id: \.self) { word in
                    Button {
                        insert(word)
                    } label: {
                        Text(word)
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(color.opacity(0.12), in: Capsule())
                            .foregroundStyle(color)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listRowSeparator(.hidden)
    }

    /// チップの語を検索文へ挿入する（スペース区切り＝決定的レイヤーはこれで接地する）。
    private func insert(_ word: String) {
        guard !criteria.contains(word) else { return }
        criteria += (criteria.isEmpty ? "" : " ") + word
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
