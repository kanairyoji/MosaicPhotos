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
/// - Parameter coalesceBelow: 0 より大きいとき、**写真数が `coalesceBelow` 未満（＝1行に満たない）の
///   連続グループを 1 セクションに束ね**、範囲ラベル（"YYYY-MM – YYYY-MM"）にする。これにより
///   1枚しかない月がヘッダー＋半端な行を量産せず、行を密に詰められる。`coalesceBelow` 以上のグループは
///   従来どおり単独セクション（自分のラベル）。0（既定）なら従来動作。
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
        let title = item.captureDate.map(label) ?? "Unknown"
        if groups.last?.label == title {
            groups[groups.count - 1].entries.append(PhotoGridEntry(flatIndex: i, item: item))
        } else {
            groups.append((title, [PhotoGridEntry(flatIndex: i, item: item)]))
        }
    }

    // 2) coalesceBelow 未満の小グループを範囲セクションへ束ねる（0/1 なら従来＝グループ＝セクション）。
    guard coalesceBelow > 1 else {
        return groups.map { PhotoGridSection(title: $0.label, rows: chunk($0.entries, colCount: colCount)) }
    }

    var result: [PhotoGridSection<Item>] = []
    var pending: [(label: String, entries: [PhotoGridEntry<Item>])] = []

    func flushPending() {
        guard !pending.isEmpty else { return }
        let merged = pending.flatMap { $0.entries }
        let first = pending.first!.label, last = pending.last!.label
        let title = first == last ? first : "\(first) – \(last)"
        result.append(PhotoGridSection(title: title, rows: chunk(merged, colCount: colCount)))
        pending = []
    }

    for g in groups {
        if g.entries.count >= coalesceBelow {
            flushPending()
            result.append(PhotoGridSection(title: g.label, rows: chunk(g.entries, colCount: colCount)))
        } else {
            pending.append(g)
        }
    }
    flushPending()
    return result
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
