import Foundation
import Testing
@testable import LocalPhotoCore

/// ⚠️ 写真ライブラリは表示中にも変わる（撮影・取り込み・削除・限定アクセスの範囲変更・
/// アルバム構成の変更）。TTL だけ、あるいは起動時の一度きりの読み込みだけでは追従できない。
@Suite("LibraryChangeFollowUp")
struct LibraryChangeFollowUpTests {

    private let day: TimeInterval = 60 * 60 * 24
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("変更があれば TTL 内でも再スキャンする")
    func dirtyForcesRescanWithinTTL() {
        let scannedAt = now.addingTimeInterval(-60)   // 1 分前＝TTL 内
        #expect(LibraryChangeFollowUp.needsRescan(scannedAt: scannedAt, isDirty: true,
                                                  now: now, ttl: day),
                "アルバム構成の変更が最大 24 時間反映されない")
    }

    @Test("変更が無ければ TTL 内はキャッシュを使う")
    func cleanCacheWithinTTLIsUsed() {
        let scannedAt = now.addingTimeInterval(-60)
        #expect(!LibraryChangeFollowUp.needsRescan(scannedAt: scannedAt, isDirty: false,
                                                   now: now, ttl: day))
    }

    @Test("TTL を超えたら再スキャンする（従来どおり）")
    func expiredCacheRescans() {
        let scannedAt = now.addingTimeInterval(-day - 1)
        #expect(LibraryChangeFollowUp.needsRescan(scannedAt: scannedAt, isDirty: false,
                                                  now: now, ttl: day))
    }

    @Test("キャッシュが無ければ必ずスキャンする")
    func missingCacheScans() {
        #expect(LibraryChangeFollowUp.needsRescan(scannedAt: nil, isDirty: false, now: now, ttl: day))
    }

    /// 索引を作ったあとに変更があれば、要求のたびに現存を確かめる
    /// （削除済み写真を返すとメンバー画面に空セルが残る）。
    @Test("索引より後の変更は現存確認を要求する")
    func changeAfterBuildRequiresExistenceCheck() {
        let built = now.addingTimeInterval(-100)
        #expect(LibraryChangeFollowUp.needsExistenceCheck(indexBuiltAt: built, lastChangeAt: now))
        #expect(!LibraryChangeFollowUp.needsExistenceCheck(indexBuiltAt: now, lastChangeAt: built),
                "作り直した後まで毎回フェッチすると索引の意味が無い")
        #expect(!LibraryChangeFollowUp.needsExistenceCheck(indexBuiltAt: now, lastChangeAt: nil))
        #expect(LibraryChangeFollowUp.needsExistenceCheck(indexBuiltAt: nil, lastChangeAt: nil),
                "索引が無いなら確かめるしかない")
    }
}
