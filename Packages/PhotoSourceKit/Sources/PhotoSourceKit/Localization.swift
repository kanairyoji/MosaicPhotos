import Foundation

/// PhotoSourceKit 内の UI 文字列を、本パッケージの String Catalog（`Localizable.xcstrings`・`.module`）で解決する。
///
/// SwiftUI のパッケージ内 `Text("key")` は既定で `Bundle.main` を見るため、パッケージ自身のカタログを
/// 使うには `.module` 指定が要る。各 API（Text/Label/Button/Section/navigationTitle 等）は `String` を
/// verbatim 表示するので、**生成時に localized 済みの String を渡す**この方式で一様にローカライズできる。
///
/// ⚠️ 新しい UI 文字列はこの関数で包み、`Localizable.xcstrings` にキー（英語原文）と訳を追加すること。
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
