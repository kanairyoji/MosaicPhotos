import Foundation
import MosaicSupport

/// PhotoSourceKit 内の UI 文字列を、本パッケージの String Catalog（`.module`）＋アプリの言語設定で解決する。
/// アプリ内の言語切替（`AppLocale.overrideCode`）に追従する。
///
/// ⚠️ 新しい UI 文字列はこの関数で包み、`Localizable.xcstrings` にキー（英語原文）と訳を追加すること。
func L(_ key: String.LocalizationValue) -> String {
    AppLocale.string(key, bundle: .module)
}
