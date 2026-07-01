import Foundation

// MARK: - Grouping model

/// グループ表示の粒度。
public enum PhotoGridGrouping: Sendable {
    case month
    case year
}

/// グリッド内の 1 セル分のエントリ。`flatIndex` は全件フラットリスト上の位置で、
/// `NavigationLink(value:)` の遷移先インデックスとして使う。
public struct PhotoGridEntry<Item> {
    public let flatIndex: Int
    public let item: Item
}

/// セルを横方向に並べた 1 行（最大 `colCount` 個）。
/// `id` は行頭エントリの `flatIndex`（全件中で一意）。
public struct PhotoGridRowData<Item>: Identifiable {
    public let id: Int
    public let entries: [PhotoGridEntry<Item>]
}

/// 日付ラベルで束ねた 1 セクション。
public struct PhotoGridSection<Item>: Identifiable {
    public var id: String { title }
    public let title: String
    public let rows: [PhotoGridRowData<Item>]
}

// MARK: - Pure grouping function

/// `items` を月/年ラベルでグループ化し、各グループを `colCount` 列の行へ分割する。
///
/// View 非依存の純関数。`PhotoItem.captureDate` が `nil` のものは "Unknown" 扱い。
/// 元の並び順（呼び出し側がソート済み）を保ったまま、隣接する同一ラベルを 1 セクションに束ねる。
///
/// - Parameter coalesceBelow: 1 より大きいとき（実用では**列数**を渡す）、**最大密度パッキング**を行う。
///   連続するグループを「合計が `coalesceBelow` 枚（＝1行ぶん）に達するまで」貪欲に蓄積して 1 セクションに
///   区切り、複数月にまたがるときは範囲ラベル（"YYYY-MM – YYYY-MM"）にする。末尾に余った 1 行未満の月は
///   直前セクションへ畳み込む。これにより「ヘッダー＋半端な1行」や孤立した小さい月を抑え、行を密に詰める
///   （各セクションは最低 1 行ぶん埋まる）。0/1（既定）なら従来＝グループ＝単独セクション。
public func photoGridSections<Item: PhotoItem>(
    items: [Item],
    grouping: PhotoGridGrouping,
    colCount: Int,
    coalesceBelow: Int = 0
) -> [PhotoGridSection<Item>] {
    // 月＝YYYY-MM / 年＝YYYY（DisplayDate で全体統一）。
    let label: (Date) -> String = grouping == .year ? DisplayDate.year : DisplayDate.ym

    // 1) 隣接同一ラベルで raw グループ化（順序保持）。
    var groups: [(label: String, entries: [PhotoGridEntry<Item>])] = []
    for (i, item) in items.enumerated() {
        // 無意味な日付（EXIF 欠落・0・1980 等）は "Unknown" に寄せる（変な年月見出しにしない）。
        let title = DisplayDate.meaningful(item.captureDate).map(label) ?? "Unknown"
        if groups.last?.label == title {
            groups[groups.count - 1].entries.append(PhotoGridEntry(flatIndex: i, item: item))
        } else {
            groups.append((title, [PhotoGridEntry(flatIndex: i, item: item)]))
        }
    }

    // 2) 最大密度パッキング：連続月を「1行ぶん（coalesceBelow 枚）」に達するまで貪欲に蓄積して区切る。
    //    末尾に余った 1 行未満の月は直前セクションへ畳み込む（最後だけ疎になるのを防ぐ）。
    //    0/1 なら従来＝グループ＝セクション（dense オフ）。
    guard coalesceBelow > 1 else {
        return groups.map { PhotoGridSection(title: $0.label, rows: chunk($0.entries, colCount: colCount)) }
    }

    // セクション単位（＝グループの配列）を先に決める。末尾余りの「直前への畳み込み」が容易になる。
    var buckets: [[(label: String, entries: [PhotoGridEntry<Item>])]] = []
    var pending: [(label: String, entries: [PhotoGridEntry<Item>])] = []
    var pendingCount = 0
    for g in groups {
        pending.append(g)
        pendingCount += g.entries.count
        if pendingCount >= coalesceBelow {     // 1 行ぶん埋まったら区切る（＝各セクションは最低 1 行満たす）
            buckets.append(pending)
            pending = []
            pendingCount = 0
        }
    }
    if !pending.isEmpty {                       // 末尾の 1 行未満の余り
        if buckets.isEmpty {
            buckets.append(pending)            // 全件で 1 行に満たない：単一セクション
        } else {
            buckets[buckets.count - 1].append(contentsOf: pending)  // 直前セクションへ畳み込む
        }
    }

    return buckets.map { bucket in
        let merged = bucket.flatMap { $0.entries }
        let first = bucket.first!.label, last = bucket.last!.label
        let title = first == last ? first : "\(first) – \(last)"
        return PhotoGridSection(title: title, rows: chunk(merged, colCount: colCount))
    }
}

// オフメイン（Task.detached）で生成して main へ渡すため、Item が Sendable なら Sendable。
extension PhotoGridEntry: Sendable where Item: Sendable {}
extension PhotoGridRowData: Sendable where Item: Sendable {}
extension PhotoGridSection: Sendable where Item: Sendable {}

/// エントリ列を `colCount` ごとの行に分割する。
private func chunk<Item>(_ entries: [PhotoGridEntry<Item>], colCount: Int) -> [PhotoGridRowData<Item>] {
    let step = max(1, colCount)
    return stride(from: 0, to: entries.count, by: step).map { start in
        let end = min(start + step, entries.count)
        return PhotoGridRowData(id: entries[start].flatIndex,
                                entries: Array(entries[start..<end]))
    }
}
