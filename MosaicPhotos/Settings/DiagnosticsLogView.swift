import MosaicSupport
import SwiftUI

/// 端末上の診断ログ（diagnostics.log）を閲覧・共有・クリアする画面。
/// Mac の Console が使えない実機でも、エラー・未捕捉例外・メモリ圧迫の記録を確認できる。
struct DiagnosticsLogView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "まだ診断ログはありません。" : text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("診断ログ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("消去", role: .destructive) {
                    DiagnosticsLog.shared.clear()
                    text = ""
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: DiagnosticsLog.shared.url)
            }
            ToolbarItem(placement: .bottomBar) {
                Button {
                    text = DiagnosticsLog.shared.recentText()
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { text = DiagnosticsLog.shared.recentText() }
    }
}
