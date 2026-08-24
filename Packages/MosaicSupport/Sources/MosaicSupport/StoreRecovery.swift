import Foundation

/// 永続ストアが開けなかったときの扱い（純ロジック・テスト対象）。
public enum StoreRecoveryPolicy: Sendable {
    /// **再構築できるキャッシュ**（サムネのメタ・タグ・埋め込み等）。破損時は削除して作り直してよい。
    case rebuildable
    /// **台帳**（バックアップ記録・オフロード台帳・未送信マーカー・共有状態）。
    /// 消すと二重アップロードや共有の齟齬になる。破損時も削除せず**退避**してから作り直す。
    case ledger
}

/// オープン失敗時にとる手（純ロジック・テスト対象）。
public enum StoreRecoveryAction: Equatable, Sendable {
    /// 一時的な失敗（容量不足・保護中）。**何も消さず**、この起動だけインメモリで動かす。
    case keepFilesUseMemory
    /// 破損・スキーマ不整合。store ファイルを削除して作り直す。
    case deleteAndRebuild
    /// 破損・スキーマ不整合だが台帳。退避（リネーム）してから作り直す。
    case quarantineAndRebuild
}

public enum StoreRecovery {

    /// ⚠️ **一時的な失敗で永続データを消さない**。以前は理由を見ずに即削除していたため、
    /// ディスク容量不足やファイル保護（端末ロック中）でも、オフロード台帳・未送信マーカー・
    /// 共有状態を失い得た（レビュー指摘）。消えると二重アップロードや共有の齟齬になる。
    public static func action(for error: Error, policy: StoreRecoveryPolicy) -> StoreRecoveryAction {
        if isTransient(error) { return .keepFilesUseMemory }
        return policy == .ledger ? .quarantineAndRebuild : .deleteAndRebuild
    }

    /// 「待てば直る」失敗か（容量不足・書き込み不可・保護中・I/O 一時障害）。
    /// 判定は根本原因（`NSUnderlyingError`）まで辿る。
    public static func isTransient(_ error: Error) -> Bool {
        var seen = 0
        var current = error as NSError?
        while let error = current, seen < 8 {
            seen += 1
            if isTransientCode(domain: error.domain, code: error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func isTransientCode(domain: String, code: Int) -> Bool {
        switch domain {
        case NSCocoaErrorDomain:
            // 640: 容量不足 / 642: 読み取り専用ボリューム / 257,513: 権限（保護中を含む）
            return [640, 642, 257, 513].contains(code)
        case NSPOSIXErrorDomain:
            // ENOSPC(28) EDQUOT(69) EPERM(1) EACCES(13) EBUSY(16) EIO(5) EAGAIN(35)
            return [28, 69, 1, 13, 16, 5, 35].contains(code)
        default:
            return false
        }
    }

    /// 退避先の名前（衝突しないよう連番）。呼び出し側が `moveItem` に使う。
    public static func quarantineURL(for url: URL, existing: (URL) -> Bool) -> URL {
        let base = url.appendingPathExtension("corrupt")
        if !existing(base) { return base }
        for n in 2...99 {
            let candidate = url.appendingPathExtension("corrupt\(n)")
            if !existing(candidate) { return candidate }
        }
        return url.appendingPathExtension("corrupt-last")
    }
}
