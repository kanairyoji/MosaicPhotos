import Foundation
import MosaicSupport

/// アプリ本体の文字列を、アプリの言語設定（`AppLocale`）＋メインバンドルのカタログで解決する。
///
/// 直書きの `Text("x")` リテラルは `.environment(\.locale)` で切り替わるが、**String 変数として渡す値**
/// （ソース行のタイトル/サブタイトル・`navigationTitle(title)` に渡す文字列・件数表示など）は verbatim
/// になり翻訳されない。それらはこの `L(_:)` で包む。
func L(_ key: String.LocalizationValue) -> String { AppLocale.string(key, bundle: .main) }
