import AutoAlbumCore
import PeopleKit
import BackupKit
import DropboxKit
import LocalPhotoKit
import MobileCLIPKit
import MosaicSupport
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

/// 開発者オプション：以前は各設定タブに散在していたデバッグ項目を 1 画面に集約する。
/// 先頭の「開発者モード」トグル（既定 OFF）が ON のときだけ詳細診断・破壊的アクションを表示する。
/// 各パッケージのデバッグは公開セクション View（`DropboxDebugSection` 等）を合成して再利用する。
///
/// 画面の並びは「情報 → 記録（ログ/計測）→ AI 解析（状況/実行/夜間/ピープル/アルバム/場所）→
/// メモリ・電源・回線 → 写真ソース（ローカル/Dropbox/バックアップ）」の順に整理している。
struct DeveloperSettingsView: View {
    /// ストア／エンジン一式（SettingsView と同じく一括で受け取り、引数漏れを防ぐ）。
    let stores: HomeStores

    private var dropboxAuth: DropboxAuthService { stores.dropboxStore.auth }
    private var store: DropboxPhotoStore { stores.dropboxStore }
    private var backupEngine: BackupEngine { stores.backupEngine }
    private var placeScanner: PlaceScanner { stores.placeScanner }
    private var autoAlbumEngine: AutoAlbumEngine { stores.autoAlbumEngine }
    private var peopleEngine: PeopleEngine { stores.peopleEngine }

    @AppStorage(AppSettingsKeys.verboseLogging) private var verboseLogging = true
    @AppStorage(AppSettingsKeys.perfTracing) private var perfTracing = false
    @AppStorage(AppSettingsKeys.faceScanOnSimulator) private var faceScanOnSimulator = false
    /// デバッグ: 重い処理のゲートを全面無効化（ランタイムのみ・再起動でリセット）。
    @State private var forceHeavyWork = BackgroundYield.debugForceHeavyWork
    @State private var heavyWorking = false
    /// BG タスク検証: 予約状態と「その場実行」中フラグ。
    @State private var bgPendingStatus = "…"
    @State private var bgDebugRunning = false

    @State private var enrichmentCount = 0
    @State private var cachedPlaceCount = 0
    @State private var isWorking = false
    @State private var placeRefineStatus = ""
    /// 顔認識の品質スナップショット（ADR-68・押したときだけ計測する）。
    @State private var faceQuality: FaceQualityReport?
    @State private var isMeasuringFaceQuality = false
    @State private var faceDetect: FaceDetectionStats.Snapshot?
    /// クラウド顔スキャンの歩留まり計測（ADR-89）。
    @State private var yieldRunner = FaceYieldMeasurementRunner()
    @State private var yieldSampleSize = 5_000

    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"

    var body: some View {
        Form {
            appInfoSection
            logsSection
            aiStatusSection
            heavyWorkDebugSection
            backgroundTaskDebugSection
            peopleDebugSection
            albumsDebugSection
            faceYieldSection
            placesDebugSection
            MemoryDebugSection()
            LocalPhotoDebugSection()
            DropboxDebugSection(dropboxAuth: dropboxAuth, store: store)
            BackupDebugSection(dropboxAuth: dropboxAuth, engine: backupEngine, dropboxStore: store)
        }
        .navigationTitle("開発者オプション")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            enrichmentCount = await autoAlbumEngine.enrichmentCount()
            cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount
        }
    }

    // MARK: - アプリ情報

    private var appInfoSection: some View {
        Section {
            LabeledContent("ビルド番号", value: build)
            LabeledContent("バンドル ID", value: Bundle.main.bundleIdentifier ?? "-")
            LabeledContent("最小 iOS バージョン",
                           value: Bundle.main.object(forInfoDictionaryKey: "MinimumOSVersion") as? String ?? "-")
            LabeledContent("端末", value: UIDevice.current.model)
        } header: {
            Text("アプリ情報")
        } footer: {
            Text("このビルドと実行中の端末の基本情報です。")
        }
    }

    // MARK: - 記録（ログ・計測）

    private var logsSection: some View {
        Section {
            NavigationLink("診断ログを見る") { DiagnosticsLogView() }
            Toggle("詳細ログを記録", isOn: $verboseLogging)
            Toggle("パフォーマンス計測", isOn: $perfTracing)
                .onChange(of: perfTracing) { _, on in PerfTrace.isEnabled = on }
        } header: {
            Text("記録（ログ・計測）")
        } footer: {
            Text("端末内の診断ログには、エラー・未捕捉例外・メモリ圧迫などが記録されます（Mac や Console 無しで "
                 + "不具合を追うため）。「詳細ログを記録」を ON にすると情報レベルの動作ログも残ります。"
                 + "「パフォーマンス計測」を ON にすると、画面遷移の所要時間（screen.*）や Dropbox の通信/"
                 + "キャッシュ/デコード時間を診断ログと os_signpost に書き出します（ON → 再現 → OFF の順で使います）。")
        }
    }

    // MARK: - AI 解析：状況（同梱モデル・件数）

    private var aiStatusSection: some View {
        Section {
            LabeledContent("メモリ使用量",
                           value: currentMemoryFootprintMB().map { String(format: "%.0f MB", $0) } ?? "—")
            LabeledContent("CLIP モデル", value: MobileCLIP.modelsBundled ? "同梱あり" : "同梱なし")
            LabeledContent("顔モデル", value: FaceModel.modelBundled ? "同梱あり" : "同梱なし")
            LabeledContent("解析済み写真", value: "\(enrichmentCount)")
            LabeledContent("地名解決した地点", value: "\(cachedPlaceCount)")
        } header: {
            Text("AI 解析：状況")
        } footer: {
            Text("オンデバイス AI に必要なモデルが同梱されているか、これまでに解析（タグ／埋め込み／地名）した "
                 + "件数を表示します。モデルが「同梱なし」の機能は無効になります。")
        }
    }

    // MARK: - AI 解析：重い処理をその場で実行

    /// 通常は「電源＋アイドル（またはロック中）」でしか動かない重い処理を、その場で動かして検証する。
    private var heavyWorkDebugSection: some View {
        Section {
            Toggle("重い処理のゲートを常に開く", isOn: $forceHeavyWork)
                .onChange(of: forceHeavyWork) { _, on in BackgroundYield.debugForceHeavyWork = on }
            LabeledContent("いま重い処理を実行してよいか", value: BackgroundYield.heavyWorkAllowed ? "はい" : "いいえ")
            Button {
                Task {
                    heavyWorking = true
                    await autoAlbumEngine.generate()
                    heavyWorking = false
                }
            } label: {
                BusyLabel("アルバムを今すぐ生成", isBusy: heavyWorking)
            }
            .disabled(heavyWorking)
            Button {
                Task {
                    heavyWorking = true
                    await autoAlbumEngine.debugRefreshAIAlbumsFull()
                    heavyWorking = false
                }
            } label: {
                BusyLabel("AI アルバムをフル再評価", isBusy: heavyWorking)
            }
            .disabled(heavyWorking)
            Button("CLIP 埋め込みを今すぐ開始") {
                autoAlbumEngine.scheduleBackgroundFill()
            }
        } header: {
            Text("AI 解析：重い処理をその場で実行")
        } footer: {
            Text("これらは通常、電源接続かつアイドル時（またはロック中の夜間タスク）にだけ動きます。"
                 + "上のトグルは、アプリを再起動するまで電源／アイドル／UI のゲートを無効化します。"
                 + "※ シミュレータでは CLIP 埋め込みは実行されません（そこでは CPU のみで遅いため）。")
        }
    }

    // MARK: - AI 解析：夜間タスク（ロック中実行の検証）

    /// ロック中実行（BGProcessingTask）の検証用。実際の「OS がロック中に起こす」瞬間は
    /// OS 裁量のため、(1) 予約されているか、(2) 最後にいつ実行されたか、(3) 同じルーチンを
    /// その場で実行して中身を確認、の 3 点で検証できるようにする。
    private var backgroundTaskDebugSection: some View {
        Section {
            LabeledContent("次回の予約", value: bgPendingLabel)
            LabeledContent("最後の夜間実行",
                           value: UserDefaults.standard.string(forKey: AppSettingsKeys.bgTaskLastRun) ?? "なし")
            Button("夜間タスクを予約し直す") {
                HeavyWorkScheduler.submit()
                Task { bgPendingStatus = await HeavyWorkScheduler.pendingStatus() }
            }
            Button {
                bgDebugRunning = true
                HeavyWorkScheduler.debugRunNow()
                // 完了検知は簡易ポーリング（表示用）。ルーチン自体は独立して走る。
                Task {
                    while HeavyWorkScheduler.isDebugRunning {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    bgDebugRunning = false
                }
            } label: {
                BusyLabel("夜間ルーチンを今すぐ実行",
                          busy: "実行中…（最大 3 分）", isBusy: bgDebugRunning)
            }
            .disabled(bgDebugRunning)
        } header: {
            Text("AI 解析：夜間タスク")
        } footer: {
            Text("デバッガ無しでロック中タスクを検証します。「夜間ルーチンを今すぐ実行」は、まったく同じ"
                 + "ルーチンを前面で実行します（ゲートを一時的に全開・3 分上限・結果は「最後の夜間実行」に "
                 + "manual-… として記録）。実際のロック中起動は OS 裁量なので、充電＋ロックで一晩置き、"
                 + "「最後の夜間実行」で確認してください。※ シミュレータでは予約は非対応で CLIP 埋め込みも省略されます。")
        }
        .task { bgPendingStatus = await HeavyWorkScheduler.pendingStatus() }
    }

    private var bgPendingLabel: String {
        switch bgPendingStatus {
        case "scheduled": return "予約あり"
        case "none":      return "予約なし"
        default:          return bgPendingStatus
        }
    }

    // MARK: - AI 解析：ピープル（顔）

    private var peopleDebugSection: some View {
        Section {
            #if targetEnvironment(simulator)
            Toggle("シミュレータでも顔スキャンする（遅い）", isOn: $faceScanOnSimulator)
            #endif
            Button("ピープルを再スキャン（修正内容は保持）", role: .destructive) {
                Task { await peopleEngine.reset() }
            }
            Button("ピープルと修正内容をリセット（学習を破棄）", role: .destructive) {
                Task { await peopleEngine.reset(includingCorrections: true) }
            }
            Button("クラスタを今すぐ再構築（制約付き）") {
                Task { await peopleEngine.debugRebuildClustersNow() }
            }
            // しきい値・マージンの効き方を数字で見る（ADR-135）。ユーザー向けにも
            // 「人物を調べる」として出している（ADR-147）ので、画面は PeopleKit 側。
            NavigationLink("人物を調べる（内訳）") {
                PersonInspectorView(peopleEngine: peopleEngine)
            }
            faceQualityRows
        } header: {
            Text("AI 解析：ピープル（顔）")
        } footer: {
            Text("顔クラスタ（人物）の再スキャン・再構築を行います。「修正内容は保持」は、あなたが直した"
                 + "名前や誤りの学習（負例）を残したまま顔を検出し直します。「学習を破棄」はそれらも消します。"
                 + "※ シミュレータの顔スキャンは既定で無効です（CPU のみで遅いため）。上のトグルで有効にできます。")
        }
    }

    // MARK: - 認識品質（ADR-68）

    /// 実機ライブラリの認識品質。正解ラベルが無いので「純度」等は出せないが、
    /// **分裂の量**（統合候補ペア）と**不変条件の破れ**（同一写真に同じ人が2回）は測れる。
    @ViewBuilder
    private var faceQualityRows: some View {
        Button(isMeasuringFaceQuality ? "計測中…" : "認識品質を計測（診断ログにも記録）") {
            Task {
                isMeasuringFaceQuality = true
                faceQuality = await peopleEngine.logQualityReport()
                faceDetect = peopleEngine.detectionStats()
                isMeasuringFaceQuality = false
            }
        }
        .disabled(isMeasuringFaceQuality)

        if let q = faceQuality {
            LabeledContent("スキャン済み写真", value: "\(q.scannedPhotos)")
            LabeledContent("うち顔が見つからなかった写真",
                           value: q.scannedPhotos > 0
                               ? "\(q.photosWithNoFace)（\(q.photosWithNoFace * 100 / q.scannedPhotos)%）"
                               : "—")
            LabeledContent("顔（未割当）", value: "\(q.faces)（\(q.unassignedFaces)）")
            LabeledContent("人物 / クラスタ", value: "\(q.people) / \(q.clusters)")
            LabeledContent("命名済み", value: "\(q.namedPeople)")
            LabeledContent("単発クラスタ", value: "\(q.singletons)")
            LabeledContent("成熟クラスタ（11顔以上）", value: "\(q.maturePeople)")
            LabeledContent("最大クラスタ", value: "\(q.largestCluster) 顔")
            LabeledContent("しきい値", value: String(format: "%.2f", q.threshold))
            LabeledContent("サイズ免除", value: q.sizeExemptionActive ? "有効（少人数）" : "無効")
            LabeledContent("統合候補ペア",
                           value: q.mergeCandidateTruncated ? "計測省略（人物が多すぎ）"
                                                            : "\(q.mergeCandidatePairs)")
            LabeledContent("同一写真違反",
                           value: q.samePhotoViolations == 0 ? "0（正常）"
                               : "\(q.samePhotoViolations)（写真 \(q.samePhotoViolationPhotos) 枚）")
            LabeledContent("学習した修正", value: "\(q.corrections)")
        }
        if let d = faceDetect, d.candidates > 0 {
            LabeledContent("検出候補（起動後）", value: "\(d.candidates)")
            LabeledContent("採用（うちフロア未満）",
                           value: "\(d.accepted)（\(d.belowQualityFloor)）")
            ForEach(d.rejectedByReason.sorted { ($0.value, $1.key) > ($1.value, $0.key) }, id: \.key) { r in
                LabeledContent("棄却: \(r.key)", value: "\(r.value)")
            }
        }
    }

    // MARK: - AI 解析：アルバム

    private var albumsDebugSection: some View {
        Section {
            LabeledContent("解析済み写真", value: "\(enrichmentCount)")
            Button("アルバムと解析データを消去", role: .destructive) {
                Task {
                    await autoAlbumEngine.clear()
                    enrichmentCount = await autoAlbumEngine.enrichmentCount()
                }
            }
        } header: {
            Text("AI 解析：アルバム")
        } footer: {
            Text("生成済みアルバムと写真の解析データ（タグ／埋め込み等）を消去します。次回の夜間処理で"
                 + "作り直されます。")
        }
    }

    // MARK: - 計測：クラウド顔スキャンの歩留まり（ADR-89）

    /// 「クラウドの埋め込み到達率が低いのはサムネが小さいから」という推定を実データで検証する。
    /// 撮影日で層化抽出した実写真を 1024px で取得し、顔の正規化サイズから
    /// 「サイズ × 顔ピクセル下限」の歩留まり表を出す（サイズごとの再取得は不要）。
    private var faceYieldSection: some View {
        Section {
            Picker("Sample size", selection: $yieldSampleSize) {
                Text("1,000").tag(1_000)
                Text("5,000").tag(5_000)
                Text("10,000").tag(10_000)
                Text("20,000").tag(20_000)
            }
            Button {
                yieldRunner.run(dropboxStore: store, sampleSize: yieldSampleSize)
            } label: {
                BusyLabel("クラウド顔スキャンの歩留まりを計測",
                          busy: "計測中… \(yieldRunner.status)", isBusy: yieldRunner.isRunning)
            }
            .disabled(yieldRunner.isRunning)
            if yieldRunner.isRunning {
                Button("中止") { yieldRunner.cancel() }
            }
            if !yieldRunner.summary.isEmpty {
                Text(yieldRunner.summary)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        } header: {
            Text("Face Yield Measurement")
        } footer: {
            Text("撮影日で層化抽出した実写真を \(FaceYieldMeasurementRunner.measurementAPISize) で取得し、"
                 + "サムネサイズ × 顔ピクセル下限ごとの歩留まりを測ります。"
                 + "通信量の目安は 1 枚 130KB 程度（10,000 枚で約 1.3GB）。Wi-Fi 推奨。"
                 + "結果は診断ログと Caches/face-yield-report.txt に残ります。")
        }
    }

    // MARK: - AI 解析：場所（Places）

    private var placesDebugSection: some View {
        Section {
            LabeledContent("地名解決した地点", value: "\(cachedPlaceCount)")
            // Apple（CLGeocoder）の地名補正を手動キック（動作確認用）。夜間の背景処理を待たずに実行し、
            // 代表トリップ 1 点の実ジオコーディング結果（サンプル）＋高精度化した地点数を表示する。
            Button {
                Task { await refinePlaceNamesNow() }
            } label: {
                BusyLabel("Apple の地名を今すぐ取得（CLGeocoder）", busy: "取得中…", isBusy: isWorking)
            }
            .disabled(isWorking)
            if !placeRefineStatus.isEmpty {
                Text(placeRefineStatus).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await rescanPlaces() }
            } label: {
                BusyLabel("場所を再スキャン", busy: "処理中…", isBusy: isWorking)
            }
            .disabled(isWorking)
            Button(role: .destructive) {
                Task { await clearAndRescanPlaces() }
            } label: {
                BusyLabel("地名キャッシュを消去して再スキャン", busy: "処理中…", isBusy: isWorking)
            }
            .disabled(isWorking)
        } header: {
            Text("AI 解析：場所（Places）")
        } footer: {
            Text("写真の位置情報を市区町村ごとにまとめる「場所」機能の診断です。地名はオフラインの都市 DB で"
                 + "即時解決し、夜間に Apple（CLGeocoder）で高精度化します。「Apple の地名を今すぐ取得」で、"
                 + "その補正を待たずに手動実行して動作確認できます。")
        }
    }

    // MARK: - ヘルパー

    private func refinePlaceNamesNow() async {
        isWorking = true
        defer { isWorking = false }
        placeRefineStatus = await autoAlbumEngine.refinePlaceNamesNow()
        cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount
    }

    private func rescanPlaces() async {
        isWorking = true
        defer { isWorking = false }
        await placeScanner.rescan()
        cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount
    }

    private func clearAndRescanPlaces() async {
        isWorking = true
        defer { isWorking = false }
        await placeScanner.clearCache()
        await placeScanner.rescan()
        cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount
    }
}
