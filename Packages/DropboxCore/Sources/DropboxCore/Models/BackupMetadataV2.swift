import Foundation

/// バックアップメタデータ v2（ADR-38）: カタログ＋撮影月シャード。
///
/// v1 は単一の `.mosaic/metadata.json` に全エントリを持ち、バックアップのたびに
/// **全件を書き直す**（6 万枚規模で 15〜25MB/回）。v2 は
/// - `.mosaic/catalog.json` … 小さな入口（スキーマ版・シャード一覧・アルバム/人物カタログ）
/// - `.mosaic/meta/<YYYY-MM>.json` … 撮影月ごとのエントリ集（**触った月だけ**更新）
/// に分割し、通信量・読み込みを有界にする。シャードの中身は v1 と同じ
/// `DropboxBackupMetadata`（entries 辞書）を流用する（Entry は v2 フィールドを Optional 追加済み）。
///
/// v1 ファイルは**凍結**（新規書き込みは v2 のみ・既存分の読み込みは継続）。
/// 読み込みは「v1（凍結ベース）→ v2 シャードで上書きマージ」の順（`DropboxPhotoStore`）。
public enum BackupMetadataV2 {

    /// カタログの相対パス（バックアップフォルダ基準）。
    public static let catalogSuffix = "/.mosaic/catalog.json"
    /// シャードの相対パス（バックアップフォルダ基準）。
    public static func shardSuffix(_ shardName: String) -> String { "/.mosaic/meta/\(shardName).json" }
    /// 撮影日不明の写真を入れるシャード名。
    public static let undatedShardName = "undated"

    /// 撮影日 → シャード名（"2025-08"）。日付不明は `undated`。
    /// タイムゾーンは UTC 固定（端末の設定に依存すると同じ写真が別シャードに入り得るため）。
    public static func shardName(for date: Date?) -> String {
        guard let date else { return undatedShardName }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month], from: date)
        guard let y = c.year, let m = c.month else { return undatedShardName }
        return String(format: "%04d-%02d", y, m)
    }
}

/// `.mosaic/catalog.json` — v2 の入口ファイル（数 KB）。
/// シャードの一覧と、写真単位でない**カタログ情報**（アルバム名・命名済み人物）を持つ。
/// 機種変更・再インストール時はここから全シャードを辿って復元する。
public struct BackupCatalog: Codable, Sendable {
    public var schemaVersion: Int
    /// 最終更新日時（ISO 8601）。
    public var updatedAt: String
    /// 存在するシャード名（"2025-08" 等）。読み込み側はこれを辿って各シャードを取得する。
    public var shards: [String]
    /// 端末のユーザー作成アルバム名の一覧（表示順）。
    public var albums: [String]
    /// 命名済み人物（顔クラスタ）のフルネーム一覧。
    public var people: [String]

    public init(shards: [String] = [], albums: [String] = [], people: [String] = []) {
        self.schemaVersion = 2
        self.updatedAt = ISO8601DateFormatter().string(from: Date())
        self.shards = shards
        self.albums = albums
        self.people = people
    }

    /// シャード追加＋カタログ情報更新（重複なし・順序維持）。
    public func updating(touchedShards: [String], albums newAlbums: [String],
                         people newPeople: [String]) -> BackupCatalog {
        var out = self
        for s in touchedShards where !out.shards.contains(s) { out.shards.append(s) }
        out.shards.sort()
        // アルバム/人物は最新の端末状態で全置換する（改名・削除を反映。写真単位の紐付けは
        // 各エントリが持つので、カタログは「現在の一覧」でよい）。空なら既存を維持する
        // （権限縮退などで一覧が取れなかった実行で消してしまわないため）。
        if !newAlbums.isEmpty { out.albums = newAlbums }
        if !newPeople.isEmpty { out.people = newPeople }
        out.updatedAt = ISO8601DateFormatter().string(from: Date())
        return out
    }
}
