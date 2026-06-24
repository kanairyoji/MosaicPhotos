import CryptoKit
import Foundation
import Testing
@testable import DropboxCore

/// PKCE（RFC 7636）の code_verifier / code_challenge 生成の正当性を検証する。
@Suite("PKCEGenerator")
struct DropboxPKCETests {

    /// base64url の許可文字集合（RFC 4648 §5、パディングなし）。
    private let base64URLChars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    @Test("code_verifier は base64url の許可文字のみ・96バイト相当の長さ")
    func verifierCharsetAndLength() {
        let verifier = PKCEGenerator.makeVerifier(byteCount: DropboxInternalConstants.pkceVerifierByteCount)
        // 96 バイトの base64（パディングなし）→ 128 文字。
        #expect(verifier.count == 128)
        // RFC 7636 の上限 128 以内・下限 43 以上。
        #expect(verifier.count >= 43 && verifier.count <= 128)
        // +, /, = を含まず、許可文字のみ。
        #expect(verifier.unicodeScalars.allSatisfy { base64URLChars.contains($0) })
    }

    @Test("code_verifier は呼び出しごとに異なる（乱数性）")
    func verifierIsRandom() {
        let count = DropboxInternalConstants.pkceVerifierByteCount
        #expect(PKCEGenerator.makeVerifier(byteCount: count) != PKCEGenerator.makeVerifier(byteCount: count))
    }

    @Test("code_challenge は base64url(SHA256(verifier)) と一致する（S256）")
    func challengeIsS256OfVerifier() {
        let verifier = "fixed-verifier-string-for-determinism"
        let challenge = PKCEGenerator.challenge(for: verifier)

        // 期待値をテスト側で独立に計算（S256 = base64url(SHA256)）。
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let expected = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        #expect(challenge == expected)
        // SHA256(32バイト)の base64url（パディングなし）→ 43 文字。
        #expect(challenge.count == 43)
        #expect(challenge.unicodeScalars.allSatisfy { base64URLChars.contains($0) })
    }
}
