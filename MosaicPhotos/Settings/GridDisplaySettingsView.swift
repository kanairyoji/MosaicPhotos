import PhotoSourceKit
import SwiftUI

/// 写真グリッドの表示設定。月グループの密度＝範囲セクションを閉じるまでに貯める「行数」を選ぶ。
/// 行数が大きいほど日付見出し（範囲ラベル）が減り、粗く・密に表示される。全ソース/アルバム共通。
struct GridDisplaySettingsView: View {
    @AppStorage(GridSettingsKeys.monthSectionRows) private var monthSectionRows = 1

    var body: some View {
        Form {
            Section {
                Picker(L("Month grouping density"), selection: $monthSectionRows) {
                    Text(L("Fine (1 row)")).tag(1)
                    Text(L("Medium (3 rows)")).tag(3)
                    Text(L("Coarse (5 rows)")).tag(5)
                }
            } footer: {
                Text(L("In month view, photos are packed densely and a date header appears each time this many rows fill up. Larger values show fewer headers and wider date ranges."))
            }
        }
        .navigationTitle(L("Photo Grid"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
