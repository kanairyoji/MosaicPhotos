import CoreGraphics
import Foundation
import MosaicSupport
import SwiftData

/// **顔の台帳（FacesV1）の控えと書き出し**（ADR-234）。
///
/// ## なぜ要るか
/// 顔まわりの不具合は**遷移のとき**にだけ出る（夜の再クラスタ・版上げの再スキャン・世代の
/// 切り替え・写真の整理）。ところが実機のライブラリは 10 万枚あり、遷移を 1 回試すのに数晩、
/// しかも**本物の名前と家族グループを賭ける**ことになる——現実には試せない。
///
/// そこで 2 つ用意する:
/// - **控えと復元**（`takeManualSnapshot` / `restoreManualSnapshot`）: `reset()` を押す前に
///   控えておけば、数分で元に戻せる。仕組みは ADR-186 の `StoreSnapshot` をそのまま使う
///   （自動の控えは「アプリの版が変わった最初の起動」で取るので、手で取る口だけを足す）。
/// - **書き出し**（`exportForReplay`）: 台帳を 1 つのフォルダに集めて共有する。
///   ⚠️ **写真本体は要らない**——顔の埋め込みは台帳の中にあるので、Mac 側のテストは
///   本物の規模・分布・名前・グループに対して `rebuildClusters` などを何度でも回せる
///   （`FaceLedgerReplayTests`）。
///
/// ## ⚠️ 個人データ
/// 書き出したファイルには**顔の埋め込みと人物名**が入る。git に入れず、`~/DEV/tmp/` の下で
/// 扱うこと（顔の評価データセットと同じ扱い）。アプリ内の控えはバックアップ対象から外れる
/// （`StoreSnapshot` が `isExcludedFromBackup` を立てる）。
public enum FaceLedgerBackup {

    /// 現行世代のコンテナ名（`FaceStore.containerName` と同じ値を公開の面に出したもの）。
    /// ⚠️ 既定引数から internal な型を参照できないので、ここに 1 つ置く。
    /// 値が 2 か所になるのを避けるため、`FaceStore` の値をそのまま写す（起動時に一度だけ）。
    public static let currentContainerName = FaceStore.containerName

    /// 手で取る控えの名前（自動の控え＝コンテナ名とは**別の置き場**にする）。
    ///
    /// ⚠️ 自動の控え（ADR-186）と同じ名前にしてはいけない。同じにすると、
    /// 「アプリの版が変わった最初の起動」で**手で取った控えが上書きされる**——
    /// `reset()` を試す前に取っておいたものが、次のビルドを入れた瞬間に消える。
    static func manualSnapshotName(for containerName: String) -> String {
        containerName + "-manual"
    }

    /// 台帳ファイルの場所（`.store`。`-wal` / `-shm` はこれに接尾辞を付けたもの）。
    static func storeURL(containerName: String) -> URL {
        ModelConfiguration(containerName, schema: FaceStore.ledgerSchema).url
    }

    /// 手で控えを取る。
    /// - Returns: 取れたか。
    @discardableResult
    public static func takeManualSnapshot(containerName: String = currentContainerName) -> Bool {
        let url = storeURL(containerName: containerName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Diagnostics.mark("faces: manual snapshot skipped — 台帳がまだ無い")
            return false
        }
        // ⚠️ `takeIfBuildChanged` は版の印で 1 回しか取らないので、手動では印を消してから呼ぶ
        //（毎回取り直せないと「試す直前の状態」を控えられない）。
        let name = manualSnapshotName(for: containerName)
        let ok = StoreSnapshot.takeIfBuildChanged(name: name, storeURL: url,
                                                  marker: UUID().uuidString)
        Diagnostics.mark("faces: manual snapshot \(ok ? "taken" : "failed") (\(name))")
        return ok
    }

    /// 手で取った控えから戻す。
    ///
    /// ⚠️ **開いているコンテナには効かない**。SwiftData はストアを掴んだままなので、
    /// ファイルを差し替えても今のプロセスは古い内容を見続ける（最悪、書き戻しで壊す）。
    /// 戻したら**アプリを再起動する**必要がある——呼び出し側はそれを画面に出すこと。
    /// - Returns: 戻せたか（控えが無ければ false）。
    @discardableResult
    public static func restoreManualSnapshot(containerName: String = currentContainerName) -> Bool {
        let ok = StoreSnapshot.restore(name: manualSnapshotName(for: containerName),
                                       storeURL: storeURL(containerName: containerName))
        Diagnostics.mark("faces: manual snapshot \(ok ? "restored（要・再起動）" : "restore failed（控えが無い）")")
        return ok
    }

    /// 手で取った控えの情報（画面に出す用）。無ければ nil。
    public static func manualSnapshotInfo(containerName: String = currentContainerName)
        -> (takenAt: Date, bytes: Int)? {
        let dir = StoreSnapshot.directory(for: manualSnapshotName(for: containerName))
        let base = storeURL(containerName: containerName).lastPathComponent
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(base).path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        var bytes = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = dir.appendingPathComponent(base + suffix).path
            bytes += (try? fm.attributesOfItem(atPath: path)[.size] as? Int) .flatMap { $0 } ?? 0
        }
        return (date, bytes)
    }

    /// Mac で回すために台帳を 1 つのフォルダへ集める（共有シートに渡す URL を返す）。
    ///
    /// ⚠️ **開いている台帳をそのままコピーする**ので、`-wal` に書き込み途中の分が残り得る。
    /// Mac 側で開けば SQLite が WAL を取り込むので読めるが、**書き込みが静かなとき**
    /// （夜間バッチが走っていないとき）に取るのが確実。
    /// - Returns: 集めたフォルダ（`FacesV1-export/`）。失敗したら nil。
    public static func exportForReplay(containerName: String = currentContainerName) -> URL? {
        let src = storeURL(containerName: containerName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            Diagnostics.mark("faces: ledger export skipped — 台帳がまだ無い")
            return nil
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("\(containerName)-export", isDirectory: true)
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let from = URL(fileURLWithPath: src.path + suffix)
                guard fm.fileExists(atPath: from.path) else { continue }
                try fm.copyItem(at: from, to: dir.appendingPathComponent(src.lastPathComponent + suffix))
            }
            // 何を持ち出したのかが後から分かるように、読み方を同梱する。
            let readme = """
                \(containerName) の台帳（顔の埋め込み・人物・名前・束ね・家族グループ）。
                ⚠️ 個人データです。git に入れないでください。

                Mac で回す:
                  mkdir -p ~/DEV/tmp/face-ledger && cp -R <このフォルダ>/* ~/DEV/tmp/face-ledger/
                  cd Packages/FaceCore
                  FACE_LEDGER_DIR=~/DEV/tmp/face-ledger swift test --filter FaceLedgerReplayTests

                写真本体は要りません（埋め込みは台帳の中にあります）。
                出力は診断ログと同じ形で標準出力に出ます。
                """
            try Data(readme.utf8).write(to: dir.appendingPathComponent("README.txt"))
            Diagnostics.mark("faces: ledger exported for replay (\(dir.lastPathComponent))")
            return dir
        } catch {
            Diagnostics.mark("faces: ledger export failed — \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - 台帳を読み直して再生する（ADR-234）

extension FaceStore {

    /// 台帳の顔を**スキャンの入力の形**（refKey → 検出結果）に戻す。
    ///
    /// ⚠️ **再スキャンを、顔検出をやり直さずに再現する**ための口。実機では 10 万枚の検出に
    /// 数晩かかるが、埋め込みは台帳に入っているので、`reset()` のあとこれを `recordScans` へ
    /// 流し込めば**同じ埋め込みで同じ写真**を入れ直せる——数秒で終わり、見たい「持ち越しの論理」
    /// だけが動く。精度は 1 ビットも変わらない（同じベクトルを入れるので）。
    ///
    /// ⚠️ **クラスタ ID は持ってこない**（持ってきたら再スキャンの再現にならない）。
    /// 撮影日は持ってくる（時期グループの分割・ADR-61 に効くため）。
    func facesAsScanInput() -> [(refKey: String, faces: [DetectedFaceSignal])] {
        var byRefKey: [String: [DetectedFaceSignal]] = [:]
        var order: [String] = []
        for face in (try? modelContext.fetch(FetchDescriptor<DetectedFace>())) ?? [] {
            if byRefKey[face.refKey] == nil { order.append(face.refKey) }
            byRefKey[face.refKey, default: []].append(DetectedFaceSignal(
                boundingBox: CGRect(x: face.bx, y: face.by, width: face.bw, height: face.bh),
                embedding: face.embedding, quality: Float(face.quality),
                hasSmile: face.hasSmile, captureDate: face.captureDate))
        }
        return order.map { (refKey: $0, faces: byRefKey[$0] ?? []) }
    }
}
