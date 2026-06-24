import CryptoKit
import Foundation
import Security

/// PKCE（RFC 7636）の code_verifier / code_challenge を生成する純ロジック。
/// `DropboxAuthService` から分離してテスト可能にする。
enum PKCEGenerator {

    /// 指定バイト数の乱数を base64url（パディングなし）した code_verifier。
    static func makeVerifier(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    /// S256 方式の code_challenge: base64url(SHA256(verifier))。
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

// MARK: - Data extension

extension Data {
    /// base64url エンコード（`+`→`-`, `/`→`_`, パディング `=` 除去）。RFC 4648 §5。
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
