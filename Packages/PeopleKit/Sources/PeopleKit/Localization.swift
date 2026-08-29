import Foundation
import MosaicSupport

/// パッケージ内の UI 文字列をローカライズする小ヘルパ（root CLAUDE.md の i18n 規約・案A）。
///
/// ⚠️ `Text("x")` 直書きは既定で `Bundle.main` を見るため、**パッケージの文字列は翻訳されない**。
/// パッケージ内では必ずこの `L(_:)` を通す（`String` を返すので Text/Label/Button に一様に効く）。
func L(_ key: String.LocalizationValue) -> String {
    AppLocale.string(key, bundle: .module)
}
