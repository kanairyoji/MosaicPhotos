import Foundation

/// クラウド写真の **パスと撮影日だけ**（ADR-224）。
///
/// ⚠️ 解析候補の列挙・重複排除に要るのはこの 2 つだけなのに、以前は表示用の `DropboxFileItem`
/// （＝SwiftData の全列を実体化）を使っていた。実機では窓の開始で 98,951 行を実体化して
/// フットプリントが 821MB まで跳ねていた（diagnostics-90）。**表示の配列を計算の入力に使わない。**
public struct CloudPhotoRef: Sendable, Equatable {
    public let path: String
    public let captureDate: Date?

    public init(path: String, captureDate: Date?) {
        self.path = path
        self.captureDate = captureDate
    }
}
