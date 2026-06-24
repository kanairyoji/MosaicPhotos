import Foundation

/// Dropbox のパス（フォルダ名）からアルバム名を抽出する1ルール。
/// `pattern`（正規表現）にマッチしたら `template`（`${name}` / `$1` などのキャプチャ参照）で名前を組み立てる。
/// 設定画面で編集し、JSON（配列）で UserDefaults に保存する。
public struct PathAlbumRule: Sendable, Codable, Equatable {
    /// パス全体（先頭 `/` 込み）に適用する正規表現。名前付き/番号キャプチャ可。
    public var pattern: String
    /// 置換テンプレート。`${name}`（名前付き）/ `$1`（番号）/ `$$`（リテラル $）を解釈する。
    public var template: String
    /// 大文字小文字を無視するか。
    public var caseInsensitive: Bool

    public init(pattern: String, template: String = "${name}", caseInsensitive: Bool = true) {
        self.pattern = pattern
        self.template = template
        self.caseInsensitive = caseInsensitive
    }
}
