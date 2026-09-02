import DropboxCore
import Foundation
import UniformTypeIdentifiers

/// どのレンディション（原画／編集結果）を上げるかの選択と、その名前づけの**純ロジック**。
///
/// ## なぜ要るか（ADR-168）
/// 旧実装は `resources.first(where: { $0.type == .photo })` を最優先していた。`.photo` は
/// **原画**で、写真アプリで編集した写真では**画面に見えているもの**ではない。つまり編集済みの
/// 写真は「編集前の姿」だけがクラウドへ上がる。オフロード（実削除）の直前検証も同じ読み取りを
/// 通るので、原画同士で hash が一致して適格になり、**編集結果はどこにも残らないまま端末から
/// 消える**（「最近削除した項目」の保存期間を過ぎると復元不能）。
///
/// そこで `.fullSizePhoto`（編集結果のレンダリング）があればそれを上げる。ただし名前は
/// **原画由来の一意なベース名 ＋ 実データの形式に対応した拡張子**にする必要がある：
/// - `.fullSizePhoto` の `originalFilename` は "FullSizeRender.jpg" のように**写真ごとに
///   一意ではない**（衝突して autorename が連発する）。
/// - 編集結果は HEIC の原画でも JPEG で書き出されることがある。原画の拡張子を流用すると
///   **`.HEIC` という名前の JPEG** ができ、共有（`ShareTempFile` は Dropbox 上の名前を
///   そのまま一時ファイル名にする）で他アプリへ誤った型として渡ることになる。
/// - 拡張子は `DeltaPageParser.imageExtensions`（Cloud 一覧の出典）に含まれるものだけを使う。
///   含まれない名前で上げると、その写真は Cloud 一覧から消える。
enum BackupRenditionNaming {

    /// `PHAssetResource.type` のうち、この判断に要る種別だけ（PhotoKit に依存しないため自前）。
    enum ResourceKind: Sendable, Equatable {
        case photo            // 原画（PHAssetResourceType.photo）
        case fullSizePhoto    // 編集結果のレンダリング（PHAssetResourceType.fullSizePhoto）
        case other
    }

    /// `PHAssetResource` の記述子（呼び出し側が PhotoKit から詰め替える）。
    struct ResourceDescriptor: Sendable, Equatable {
        let kind: ResourceKind
        let originalFilename: String
        let uniformTypeIdentifier: String?

        init(kind: ResourceKind, originalFilename: String, uniformTypeIdentifier: String?) {
            self.kind = kind
            self.originalFilename = originalFilename
            self.uniformTypeIdentifier = uniformTypeIdentifier
        }
    }

    /// 選んだレンディション。
    struct Selection: Sendable, Equatable {
        /// 渡された配列の添字（呼び出し側が対応する `PHAssetResource` を引く）。
        let index: Int
        /// 編集結果（`.fullSizePhoto`）を選んだか。
        let isEdited: Bool
    }

    /// 上げるレンディションを選ぶ。
    ///
    /// **編集結果があればそれを最優先**する（無ければ従来どおり原画＝未編集の挙動と同じ）。
    static func select(_ resources: [ResourceDescriptor]) -> Selection? {
        if let index = resources.firstIndex(where: { $0.kind == .fullSizePhoto }) {
            return Selection(index: index, isEdited: true)
        }
        if let index = resources.firstIndex(where: { $0.kind == .photo }) {
            return Selection(index: index, isEdited: false)
        }
        return resources.isEmpty ? nil : Selection(index: 0, isEdited: false)
    }

    /// アップロードに使うファイル名を決める。
    ///
    /// - 未編集: 従来どおり `originalFilename`（空なら `fallback`）＝**名前は不変**
    ///   （既存バックアップの再アップロードを起こさない）。
    /// - 編集済み: 原画の stem ＋ `-edited` ＋ **実際に上げるデータの形式**に対応する拡張子。
    ///   型が決められない、または画像拡張子の集合に無い場合は **nil（＝上げない）**——
    ///   誤った名前でアップロードするより、その 1 枚をスキップする方が安全。
    static func filename(resources: [ResourceDescriptor], selection: Selection,
                         localIdentifier: String, fallback: String, data: Data) -> String? {
        let selected = resources[selection.index]
        guard selection.isEdited else {
            return selected.originalFilename.isEmpty ? fallback : selected.originalFilename
        }
        // stem は**原画**の名前から取る（編集レンディションの名前は写真ごとに一意でない）。
        let originalName = resources.first(where: { $0.kind == .photo })?.originalFilename ?? ""
        let stem = originalName.isEmpty
            ? stableStem(forLocalIdentifier: localIdentifier)
            : (originalName as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }
        guard let ext = fileExtension(uti: selected.uniformTypeIdentifier, data: data) else {
            return nil
        }
        return "\(stem)-edited.\(ext)"
    }

    /// localIdentifier 由来の安定した stem（原画リソースが無い写真用・一意性は現状と同じ性質）。
    static func stableStem(forLocalIdentifier id: String) -> String {
        "photo_" + id.prefix(8).replacingOccurrences(of: "/", with: "-")
    }

    // MARK: - 拡張子の決定

    /// UTI → 拡張子。決まらなければ先頭バイトの形式判定にフォールバックする。
    /// どちらでも決まらない、または画像拡張子の集合に無ければ nil（＝名前を作らない）。
    static func fileExtension(uti: String?, data: Data) -> String? {
        let candidates = [uti.flatMap(extensionFromUTI), sniffExtension(data)]
        for candidate in candidates {
            guard let candidate else { continue }
            if DeltaPageParser.imageExtensions.contains(candidate) { return candidate }
        }
        return nil
    }

    private static func extensionFromUTI(_ uti: String) -> String? {
        guard let ext = UTType(uti)?.preferredFilenameExtension?.lowercased() else { return nil }
        // "jpeg" は Cloud 一覧の集合にもあるが、既存の命名（IMG_xxxx.jpg）に揃える。
        return ext == "jpeg" ? "jpg" : ext
    }

    /// 先頭バイトの形式判定（UTI が取れない実機ケースの保険）。
    static func sniffExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 12 else { return nil }
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpg" }
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes[0] == 0x49, bytes[1] == 0x49, bytes[2] == 0x2A, bytes[3] == 0x00 { return "tif" }
        if bytes[0] == 0x4D, bytes[1] == 0x4D, bytes[2] == 0x00, bytes[3] == 0x2A { return "tif" }
        // ISO BMFF（HEIF/HEIC）: 4..8 が "ftyp"。
        if bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            let heifBrands: Set<String> = ["heic", "heix", "hevc", "heim", "heis", "hevm",
                                           "hevs", "mif1", "msf1"]
            if heifBrands.contains(brand) { return "heic" }
        }
        return nil
    }
}
