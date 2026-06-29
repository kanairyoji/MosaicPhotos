import Foundation

/// アプリの表示言語。`system` は端末設定に従う（日本語端末→日本語、それ以外→英語）。
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case ja
    case en
}

/// アプリ内の言語切替を全パッケージ横断で実現するファサード。
///
/// SwiftUI の `Text` はアプリ本体では `.environment(\.locale)` で言語が切り替わるが、
/// パッケージ内の `String(localized:bundle:.module)` は環境ロケールを見ない。そこで各パッケージの
/// `L(_:)` ヘルパーは本 `AppLocale.string(_:bundle:)` を通し、`overrideCode` があればその言語の
/// `lproj` バンドル＋ロケールで解決する（端末設定に依らず日本語/英語へ即切替できる）。
public enum AppLocale {
    /// `@AppStorage` / `UserDefaults` のキー（設定 UI と共有）。
    public static let key = "app.language"

    /// 上書き言語コード（nil=端末設定に従う）。設定変更時・起動時に更新する。
    nonisolated(unsafe) public static var overrideCode: String?

    /// 設定値（`AppLanguage`）を反映する。
    public static func apply(_ language: AppLanguage) {
        overrideCode = (language == .system) ? nil : language.rawValue
    }

    /// 永続値から `overrideCode` を読み込む（アプリ起動時に呼ぶ）。
    public static func loadFromDefaults() {
        let raw = UserDefaults.standard.string(forKey: key) ?? AppLanguage.system.rawValue
        apply(AppLanguage(rawValue: raw) ?? .system)
    }

    /// SwiftUI に渡すロケール（アプリ本体の `Text` リテラル切替用）。
    public static var resolvedLocale: Locale {
        if let overrideCode { return Locale(identifier: overrideCode) }
        return .autoupdatingCurrent
    }

    /// 実効表示言語が日本語か（上書き言語＝なければ端末言語）。地名など UI 言語に追従させる用途。
    public static var isJapanese: Bool {
        let code = overrideCode ?? Locale.autoupdatingCurrent.language.languageCode?.identifier
        return code == "ja"
    }

    /// 文字列を上書き言語（無ければ bundle 既定＝端末設定）で解決する。
    /// 各パッケージの `L(_:)` から `bundle: .module` で呼ぶ。
    public static func string(_ key: String.LocalizationValue, bundle: Bundle) -> String {
        guard let code = overrideCode else {
            return String(localized: key, bundle: bundle)
        }
        let target: Bundle = {
            if let path = bundle.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) {
                return b
            }
            return bundle   // 例: en は base 言語のため en.lproj が無いことがある
        }()
        return String(localized: key, bundle: target, locale: Locale(identifier: code))
    }
}
