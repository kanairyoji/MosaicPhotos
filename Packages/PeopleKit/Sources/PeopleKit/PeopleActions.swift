#if canImport(UIKit)
import AutoAlbumCore
import BackupKit
import SwiftUI

// MARK: - People actions (長押しメニューと配下のシート/アラート一式)

/// ピープル長押しメニュー（名前変更／代表写真の変更／顔の管理）と、その配下のシート・アラートを
/// 1 つにまとめたモディファイア。HomeView に @State とプレゼンテーションが 5 つ居座っていたのを
/// 分離し、HomeView はルーティング（`target` の Binding を渡す）に専念する。
struct PeopleActionsModifier: ViewModifier {
    /// 長押しされた人物（HomeSections の PeopleCarousel が設定する）。nil で閉じる。
    @Binding var target: PersonInfo?
    let peopleEngine: PeopleEngine

    /// 名前変更中の対象と入力テキスト。
    @State private var renamingPerson: PersonInfo?
    @State private var renameText: String = ""
    /// 代表写真ピッカーの対象。
    @State private var coverPickerPerson: PersonInfo?
    /// 顔の管理（どの顔を認識したか確認・別の人へ付け替え）の対象。
    @State private var manageFacesPerson: PersonInfo?
    /// 別の人物へ統合する対象（統合元）。
    @State private var mergeSourcePerson: PersonInfo?
    /// 「この人物を整理」（混入グループの一括分離・ADR-111）の対象。
    @State private var cleanupPerson: PersonInfo?
    /// クラウド共有（共有セット作成・ADR-112）の対象。エンジン未注入なら項目を出さない。
    @Environment(ShareSyncEngine.self) private var shareEngine: ShareSyncEngine?
    @AppStorage(ShareSettingsKeys.provideEnabled) private var shareProvideEnabled = true
    @State private var sharePerson: SharePersonPayload?
    /// クラウド共有の停止対象（共有中のときだけメニューに出す）。
    @State private var stoppingShare: StopSharingTarget?

    /// 共有シートの素材。写真キーは開く前に解決する
    /// （一覧の `PersonInfo.memberRefKeys` は遅延取得で空のため・ADR-95）。
    private struct SharePersonPayload: Identifiable {
        let person: PersonInfo
        let refKeys: [String]
        var id: Int { person.clusterID }
    }

    func body(content: Content) -> some View {
        content
            // ピープル長押し → メニュー（名前変更／代表写真の変更／顔の管理）。
            .confirmationDialog(target?.displayName ?? "",
                                isPresented: Binding(get: { target != nil },
                                                     set: { if !$0 { target = nil } }),
                                presenting: target) { person in
                Button(L("Rename")) { renamingPerson = person; renameText = person.name ?? "" }
                Button(L("Choose Cover Photo")) { coverPickerPerson = person }
                Button(L("Manage Faces")) { manageFacesPerson = person }
                Button(L("Group with Another Person…")) { mergeSourcePerson = person }
                // 混入（複数の別人が同じ人物に入っている）をグループ単位で一括分離する（ADR-111）。
                Button(L("Clean Up This Person…")) { cleanupPerson = person }
                // 共有中なら「停止」、していなければ「共有…」——同じ場所で対になるようにする。
                if let shareEngine, shareProvideEnabled {
                    if let setID = shareEngine.sharedSetID(
                        sourceKey: ShareSourceKey.person(person.clusterID).encoded,
                        name: person.displayName) {
                        Button(L("Stop Cloud Sharing…"), role: .destructive) {
                            stoppingShare = StopSharingTarget(setID: setID,
                                                              name: person.displayName)
                        }
                    } else {
                        Button(L("Cloud Share…")) {
                            Task {
                                let refKeys = await peopleEngine.memberRefKeys(forPerson: person.clusterID)
                                sharePerson = SharePersonPayload(person: person, refKeys: refKeys)
                            }
                        }
                    }
                }
                if person.isGrouped {
                    Button(L("Separate Grouped Person"), role: .destructive) {
                        let id = person.clusterID
                        Task { await peopleEngine.ungroupPerson(clusterID: id) }
                    }
                }
                Button(L("Cancel"), role: .cancel) {}
            }
            // 代表写真ピッカー。
            .sheet(item: $coverPickerPerson) { person in
                PersonCoverPickerView(person: person, peopleEngine: peopleEngine)
            }
            // 顔の管理（認識した顔の確認・別の人へ付け替え）。
            .sheet(item: $manageFacesPerson) { person in
                PersonPhotosView(person: person, peopleEngine: peopleEngine)
            }
            // 別の人物へ統合（同一人物が 2 つに割れたときの修正）。
            .sheet(item: $mergeSourcePerson) { person in
                PersonMergePickerView(source: person, peopleEngine: peopleEngine)
            }
            // この人物を整理（混入グループの一括分離・ADR-111）。
            .sheet(item: $cleanupPerson) { person in
                PersonCleanupView(person: person, peopleEngine: peopleEngine)
            }
            // クラウド共有（この人物の写真で共有セットを作る・ADR-112）。
            .sheet(item: $sharePerson) { payload in
                if let shareEngine {
                    ShareSetCreationSheet(suggestedName: payload.person.displayName,
                                          refKeys: payload.refKeys,
                                          shareEngine: shareEngine,
                                          sourceKey: ShareSourceKey.person(payload.person.clusterID).encoded)
                }
            }
            .stopSharingConfirmation($stoppingShare, shareEngine: shareEngine)
            // 名前変更（入力アラート）。空欄で保存すると "Person N" に戻る。
            .alert(L("Rename Person"),
                   isPresented: Binding(get: { renamingPerson != nil },
                                        set: { if !$0 { renamingPerson = nil } }),
                   presenting: renamingPerson) { person in
                TextField(L("Name"), text: $renameText)
                Button(L("Cancel"), role: .cancel) { renamingPerson = nil }
                Button(L("Save")) {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await peopleEngine.rename(clusterID: person.clusterID, name: trimmed.isEmpty ? nil : trimmed) }
                    renamingPerson = nil
                }
            }
    }
}

extension View {
    /// ピープル長押しメニューと配下の UI 一式を付ける。`target` に人物を入れるとメニューが開く。
    public func peopleActions(for target: Binding<PersonInfo?>, engine: PeopleEngine) -> some View {
        modifier(PeopleActionsModifier(target: target, peopleEngine: engine))
    }
}
#endif
