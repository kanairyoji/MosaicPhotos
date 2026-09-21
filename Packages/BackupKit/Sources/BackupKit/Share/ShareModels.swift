import Foundation
import SwiftData

/// 共有セットの**作成元**（どのカードから作られたか）。
///
/// 文字列プロトコル（`"album-…"` 等）の符号化/復号を 1 か所に閉じる。以前は生成側 3 ファイル・
/// 復号側 1 ファイルに素のリテラルと `dropFirst(7)` が散らばっており、画面ルーティング用の
/// `HomeDestination.id` が**同じ接頭辞を別の意味で**使っていて紛らわしかった（規約: 文字列
/// リテラルを読み手・書き手に重複させない）。
public enum ShareSourceKey: Equatable, Sendable {
    case album(String)
    case person(Int)
    case group(UUID)

    private static let albumPrefix = "album-"
    private static let personPrefix = "person-"
    private static let groupPrefix = "pgroup-"

    public var encoded: String {
        switch self {
        case .album(let id):  return Self.albumPrefix + id
        case .person(let id): return Self.personPrefix + String(id)
        case .group(let id):  return Self.groupPrefix + id.uuidString
        }
    }

    /// 種類（album / person / group）。**同名でも種類が違えば別物**として扱うために使う。
    public enum Kind: String, Sendable { case album, person, group }

    public var kind: Kind {
        switch self {
        case .album:  return .album
        case .person: return .person
        case .group:  return .group
        }
    }

    public init?(_ raw: String) {
        if raw.hasPrefix(Self.groupPrefix) {
            guard let uuid = UUID(uuidString: String(raw.dropFirst(Self.groupPrefix.count))) else { return nil }
            self = .group(uuid)
        } else if raw.hasPrefix(Self.personPrefix) {
            guard let id = Int(raw.dropFirst(Self.personPrefix.count)) else { return nil }
            self = .person(id)
        } else if raw.hasPrefix(Self.albumPrefix) {
            let id = String(raw.dropFirst(Self.albumPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .album(id)
        } else {
            return nil
        }
    }
}

/// 共有セット（＝共有フォルダ内のサブフォルダ 1 つ）。
/// 「共有はバックアップの射影」——実体はバックアップ（またはクラウド原本）からの
/// サーバーサイドコピーで、セット削除は共有側のフォルダ削除のみ（正本は無傷）。
@Model
public final class ShareSet {
    @Attribute(.unique) public var id: UUID
    /// 表示名（ユーザー入力そのまま）。
    public var name: String
    /// 実フォルダ名（`ShareNaming.folderName` 済み・共有ルート直下）。
    public var folderName: String
    public var createdAt: Date
    /// 作成元（"pgroup-<uuid>" / "person-<clusterID>" / "album-<id>"）。
    /// 元のカードに「クラウド共有中」バッジを出すための参照。手動作成は nil。
    public var sourceKey: String?
    /// **最後の反映で共有済みだった枚数**（画面の「N/M」表示用のキャッシュ・ADR-209）。
    ///
    /// ⚠️ これは**真実ではなく表示の控え**。真実は Dropbox の実在で、反映のたびに数え直す。
    /// 以前はアイテムごとに 4 状態を持っていたが、状態と実在が食い違ったときに直す仕組みが
    /// 要り、それが孤児・取りこぼし・収束しない反映の温床になっていた。
    public var lastSyncedPresent: Int?
    /// 最後の反映でバックアップ待ちだった枚数（同上）。
    public var lastSyncedWaiting: Int?

    public init(id: UUID = UUID(), name: String, folderName: String,
                createdAt: Date = Date(), sourceKey: String? = nil) {
        self.id = id
        self.name = name
        self.folderName = folderName
        self.createdAt = createdAt
        self.sourceKey = sourceKey
    }
}

/// 共有セットの 1 メンバー（写真 1 枚）。
///
/// ⚠️ **状態を持たない**（ADR-209）。「コピー済みか」は Dropbox の実在が答えるので、
/// 記録に持つと食い違いが生まれる。ここが持つのは「このセットにこの写真が入っている」だけ。
@Model
public final class ShareItem {
    public var setID: UUID
    /// 写真の統一キー（"L-<localIdentifier>" / "C-<Dropbox パス>"）。
    public var refKey: String
    public var addedAt: Date

    public init(setID: UUID, refKey: String, addedAt: Date = Date()) {
        self.setID = setID
        self.refKey = refKey
        self.addedAt = addedAt
    }
}

// MARK: - Sendable 値（actor 境界の外へ @Model を漏らさない・プロジェクト規約）

public struct ShareSetLite: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let folderName: String
    public let createdAt: Date
    public let sourceKey: String?

    public init(id: UUID, name: String, folderName: String, createdAt: Date,
                sourceKey: String? = nil) {
        self.id = id
        self.name = name
        self.folderName = folderName
        self.createdAt = createdAt
        self.sourceKey = sourceKey
    }
}

public struct ShareItemLite: Sendable, Equatable {
    public let refKey: String
    public let addedAt: Date

    public init(refKey: String, addedAt: Date) {
        self.refKey = refKey
        self.addedAt = addedAt
    }
}
