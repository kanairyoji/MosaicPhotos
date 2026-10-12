import Foundation

/// バックアップ先の選択肢。
/// `@AppStorage` で永続化するため `String` raw value を使用する。
///
/// ⚠️ ADR-275 から `.disabled` の意味は「**何も上げない**」ではなく
/// 「**自動では上げない**（共有に入れた端末写真だけ上げる）」。キーと値は据え置き
/// （移行なし）で、意味の読み替えは `BackupScope` の 1 か所でだけ行う。
public enum BackupDestination: String, CaseIterable {
    case disabled
    case dropbox
}

/// **どの端末写真を Dropbox へ上げるか**（ADR-275）。
///
/// 仕組み（アップロード経路・背景転送・メタデータ・夜間の手）は 1 つで、違うのは対象だけ:
/// - `.everything`: ライブラリの全写真（自動バックアップ）。共有で待たれている写真が先頭。
/// - `.sharedOnly`: 共有セットに入れた端末写真だけ。共有は「バックアップ済みのファイルを
///   Share フォルダへコピーする」作りなので、共有したい写真だけを同じ経路で上げる。
///
/// ⚠️ 共有から外した写真は **Backup フォルダに残す**（消さない）。消すには「共有のためだけに
/// 上げた」という記録と削除の経路が要り、不可逆な操作を 1 つ増やすことになるため。
public enum BackupScope: Sendable, Equatable {
    case everything
    case sharedOnly

    public init(_ destination: BackupDestination) {
        self = destination == .dropbox ? .everything : .sharedOnly
    }

    /// 設定から読む。⚠️ 設定の読み手は**ここだけ**にする（`destination` を直接比べない）。
    public static func current(_ defaults: UserDefaults) -> BackupScope {
        BackupScope(defaults.string(forKey: BackupSettingsKeys.destination)
            .flatMap(BackupDestination.init(rawValue:)) ?? .disabled)
    }
}

/// 対象の違いから決まる「やるか・やらないか」（ADR-275・純ロジック）。
///
/// ⚠️ 呼び出し側で `scope == .everything` を書かない。判断が散ると片方だけ直す形になる（ADR-196）。
enum BackupScopePolicy {

    /// このバックアップ実行で上げる写真（順序つき）。
    ///
    /// - `library`: 候補の localIdentifier（表示順）。`.sharedOnly` では共有メンバーだけを
    ///   渡してよい（全ライブラリを列挙しないため）。
    /// - `awaitedByShare`: 共有セットの端末写真（「提供する」が OFF なら空）。
    /// - `limit`: 1 回の上限（0 以下で無制限）。⚠️ **共有で待たれている写真は上限に数えない**
    ///   ——利用者が「共有する」と明示した写真で、上限で切ると共有が何日も進まない。
    ///   （以前は上限を先に掛けてから共有メンバーを前へ出していたので、上限の外にいる
    ///   共有メンバーは優先されなかった。）
    static func uploadTargets(library: [String], alreadyUploaded: Set<String>,
                              awaitedByShare: Set<String>, scope: BackupScope,
                              limit: Int) -> (pending: [String], skipped: Int, prioritized: Int) {
        var awaited: [String] = []
        var rest: [String] = []
        var skipped = 0
        for id in library {
            if alreadyUploaded.contains(id) { skipped += 1; continue }
            if awaitedByShare.contains(id) { awaited.append(id) }
            else if scope == .everything { rest.append(id) }
        }
        if limit > 0, rest.count > limit { rest = Array(rest.prefix(limit)) }
        return (awaited + rest, skipped, awaited.count)
    }

    /// 候補をどこまで列挙するか。nil＝全ライブラリ、集合＝その写真だけ（`.sharedOnly`）。
    static func candidateRestriction(scope: BackupScope,
                                     awaitedByShare: Set<String>) -> Set<String>? {
        scope == .everything ? nil : awaitedByShare
    }

    /// 夜間・手動の実行を始める意味があるか。
    /// `.sharedOnly` で待っている共有写真が無いなら、写真ライブラリの列挙もしない。
    static func hasWork(scope: BackupScope, awaitedCount: Int) -> Bool {
        scope == .everything || awaitedCount > 0
    }

    /// オフロード（端末から消す）を許すか。⚠️ `.sharedOnly` では許さない——
    /// 「自動では上げない」と選んだ利用者の写真が、共有しただけで端末から消えるのは驚き。
    static func allowsOffload(scope: BackupScope) -> Bool {
        scope == .everything
    }

    /// 週次の照合（記録と Dropbox の突き合わせ）を走らせるか。
    /// `.sharedOnly` でも上げた写真があれば走らせる（Backup フォルダで消された写真の記録を
    /// 掃除しないと、共有のコピー元が無いまま失敗し続ける）。上げたものが無ければ一覧を引かない。
    static func allowsReconcile(scope: BackupScope, hasUploads: () -> Bool) -> Bool {
        scope == .everything || hasUploads()
    }
}
