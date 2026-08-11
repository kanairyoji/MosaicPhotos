import MosaicSupport
import PhotoSourceKit
import SwiftUI

/// 端末上の診断ログ（diagnostics.log）を閲覧・共有・クリアする画面。
/// Mac の Console が使えない実機でも、エラー・未捕捉例外・メモリ圧迫の記録を確認できる。
///
/// ⚠️ 表示のしかたが性能そのもの（ADR-99）。以前は全文（最大 512KB）を**同期で**読み、
/// 1 つの `Text` に流し込んでいたため、画面を開くとメインが数秒止まっていた
/// （実フィードバック「デバッグログを見るところで固まる」）。
/// (1) 読み込みは `async`（`recentLines`）、(2) 描画は行単位の `LazyVStack`＝
/// 見えている行だけレイアウトする、の 2 点で解消する。全文が要るときは共有ボタンを使う。
struct DiagnosticsLogView: View {
    @State private var lines: [String] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                Color.clear.busyOverlay(true, text: "読み込み中…")
            } else if lines.isEmpty {
                Text("まだ診断ログはありません。")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // ⚠️ 1 行 1 ビュー。行番号（offset）を id にすると内容が変わっても
                        //    再利用が効き、更新時のちらつきが少ない。
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("診断ログ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("消去", role: .destructive) {
                    DiagnosticsLog.shared.clear()
                    lines = []
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // 全文が要るときはこちら（画面には末尾のみ出す）。
                ShareLink(item: DiagnosticsLog.shared.url)
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Task { await load() }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        lines = await DiagnosticsLog.shared.recentLines()
        isLoading = false
    }
}
