import Foundation
import MosaicSupport

/// LocalPhotoKit の UI 文字列を `.module` カタログ＋アプリの言語設定（`AppLocale`）で解決する。
func L(_ key: String.LocalizationValue) -> String { AppLocale.string(key, bundle: .module) }
