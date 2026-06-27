#if canImport(UIKit)
import MosaicSupport
import SwiftUI
import UIKit

/// 月グループで束ねる写真数の固定しきい値（列数非依存。これ未満の連続月を範囲セクションへ束ねる）。
private let gridCoalesceThreshold = 4

/// UICollectionView を土台にした写真グリッド（SwiftUI ラッパー）。
///
/// SwiftUI の `ScrollView` + `LazyVGrid` は数万件規模で programmatic スクロールが不安定
/// （`scrollTo(id:)` が未実体化の遠い項目へ飛べない）・性能も伸び悩むため、写真アプリと同じ
/// `UICollectionView` に置き換える。これにより：
/// - 右端スクラバーは `contentOffset` を直接セットするのでどんな大ジャンプも確実。
/// - セル再利用が本物で 6.7万件でも軽い。先読みは `UICollectionViewDataSourcePrefetching`。
/// - スクロールで通り過ぎるセルは `prepareForReuse` で取得をキャンセル（画像は後追い）。
///
/// 列数（ズーム段階）・日付グルーピング（月/年）・ピンチ・タップ遷移は呼び出し側（`PhotoGridView`）
/// から制御する。
struct PhotoCollectionView<Store: PhotoStore>: UIViewRepresentable {
    let store: Store
    /// 表示アイテムのスナップショット（差分検出用。変化時に updateUIView で再適用）。
    let items: [Store.Item]
    /// 1 行あたりの列数。
    let columnCount: Int
    /// 日付セクション分け。nil = セクションなし（dense）。
    let grouping: PhotoGridGrouping?
    /// ピンチ終了時のスケール（>1 拡大／<1 縮小）。
    let onPinch: (CGFloat) -> Void
    /// セルタップ時に開く item.id。
    let onSelect: (Store.Item.ID) -> Void
    /// スクラブの開始(true)/終了(false)。背景処理の一時停止に使う。
    let onScrubbingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, onPinch: onPinch, onSelect: onSelect, onScrubbingChange: onScrubbingChange)
    }

    func makeUIView(context: Context) -> UIView {
        context.coordinator.makeContainer(columns: max(1, columnCount), grouped: grouping != nil)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(items: items, columns: max(1, columnCount), grouping: grouping)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
        private let store: Store
        private let onPinch: (CGFloat) -> Void
        private let onSelect: (Store.Item.ID) -> Void
        private let onScrubbingChange: (Bool) -> Void

        private var collectionView: UICollectionView!
        private var dataSource: UICollectionViewDiffableDataSource<String, Store.Item.ID>!
        private let scrubber = GridScrubberView()

        /// 現在の一覧（COW で store の配列とバッファ共有＝追加コピーは軽い）と、id→index の対応。
        /// 以前は id→Item の dict（67k 件の構造体コピー＝約10MB）だったが、index 参照に変えてメモリ削減。
        private var items: [Store.Item] = []
        private var idToIndex: [Store.Item.ID: Int] = [:]
        /// 現在適用済みの構成シグネチャ（再適用の要否判定）。
        private var appliedSignature = ""
        private var currentColumns = 0
        private var currentGrouped = false
        private var didInitialScroll = false
        /// 非同期スナップショット構築の世代。古い構築結果を破棄するため。
        private var snapshotToken = 0

        private let spacing: CGFloat = 2

        init(store: Store, onPinch: @escaping (CGFloat) -> Void,
             onSelect: @escaping (Store.Item.ID) -> Void,
             onScrubbingChange: @escaping (Bool) -> Void) {
            self.store = store
            self.onPinch = onPinch
            self.onSelect = onSelect
            self.onScrubbingChange = onScrubbingChange
            super.init()
        }

        // MARK: Setup

        func makeContainer(columns: Int, grouped: Bool) -> UIView {
            currentColumns = columns
            currentGrouped = grouped

            let layout = makeLayout(columns: columns, grouped: grouped)
            let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
            cv.backgroundColor = .systemBackground
            cv.alwaysBounceVertical = true
            cv.delegate = self
            cv.prefetchDataSource = self
            collectionView = cv

            configureDataSource(cv)

            // ピンチでズーム段階を変える。
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            cv.addGestureRecognizer(pinch)

            // スクラバー（UIKit）。contentOffset を直接動かすので大ジャンプも確実。
            scrubber.onScrub = { [weak self] fraction in self?.scrollTo(fraction: fraction) }
            scrubber.onActive = { [weak self] active in self?.onScrubbingChange(active) }

            let container = UIView()
            cv.translatesAutoresizingMaskIntoConstraints = false
            scrubber.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(cv)
            container.addSubview(scrubber)
            NSLayoutConstraint.activate([
                cv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                cv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                cv.topAnchor.constraint(equalTo: container.topAnchor),
                cv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                scrubber.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrubber.topAnchor.constraint(equalTo: container.topAnchor),
                scrubber.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                scrubber.widthAnchor.constraint(equalToConstant: 44),
            ])
            return container
        }

        private func makeLayout(columns: Int, grouped: Bool) -> UICollectionViewLayout {
            let cols = max(1, columns)
            let fraction = 1.0 / CGFloat(cols)
            // item 幅を 1/cols にし、subitems:[item] でグループが cols 個で自動的に埋まる。
            // セル間の隙間は contentInsets（各辺 spacing/2）で作る（interItemSpacing だと
            // 合計幅が超過して列が折り返す古典的問題があるため使わない）。
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .fractionalWidth(fraction),
                heightDimension: .fractionalHeight(1.0)))
            item.contentInsets = NSDirectionalEdgeInsets(
                top: spacing / 2, leading: spacing / 2, bottom: spacing / 2, trailing: spacing / 2)
            // グループ高 = コンテナ幅 × 1/cols ＝ 正方形の行。
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1.0),
                                  heightDimension: .fractionalWidth(fraction)),
                subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            if grouped {
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(32)),
                    elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
                header.pinToVisibleBounds = true
                section.boundarySupplementaryItems = [header]
            }
            return UICollectionViewCompositionalLayout(section: section)
        }

        private func configureDataSource(_ cv: UICollectionView) {
            let cellReg = UICollectionView.CellRegistration<GridThumbnailCell, Store.Item.ID> { [weak self] cell, _, id in
                guard let self, let index = self.idToIndex[id], index < self.items.count else { return }
                let item = self.items[index]
                let px = self.cellPixelSize()
                let store = self.store
                cell.configure { await store.thumbnail(for: item, targetSize: px) }
            }
            dataSource = UICollectionViewDiffableDataSource<String, Store.Item.ID>(collectionView: cv) {
                cv, indexPath, id in
                cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: id)
            }
            let headerReg = UICollectionView.SupplementaryRegistration<GridSectionHeaderView>(
                elementKind: UICollectionView.elementKindSectionHeader
            ) { [weak self] view, _, indexPath in
                guard let self else { return }
                let sections = self.dataSource.snapshot().sectionIdentifiers
                view.title = indexPath.section < sections.count ? sections[indexPath.section] : nil
            }
            dataSource.supplementaryViewProvider = { cv, _, indexPath in
                cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
            }
        }

        // MARK: Update / snapshot

        func update(items: [Store.Item], columns: Int, grouping: PhotoGridGrouping?) {
            let grouped = grouping != nil
            // レイアウト（列数/グルーピング）が変わったら作り直す。
            if columns != currentColumns || grouped != currentGrouped {
                currentColumns = columns
                currentGrouped = grouped
                collectionView.setCollectionViewLayout(makeLayout(columns: columns, grouped: grouped), animated: false)
            }
            scrubber.isHidden = items.count <= 60

            // ⚠️ 列数はシグネチャに含めない：列変更（ピンチ）はレイアウト作り直しだけで済み、
            //   スナップショット（id→index・グルーピング）は内容/グルーピング種別が変わらない限り
            //   作り直さない（68k で 0.5〜1s の再構築を繰り返さないため）。coalesce も列非依存。
            let signature = "\(items.count)|\(String(describing: grouping))|\(items.first.map { "\($0.id)" } ?? "")|\(items.last.map { "\($0.id)" } ?? "")"
            if signature != appliedSignature {
                appliedSignature = signature
                applySnapshot(items: items, grouping: grouping)
            } else if !didInitialScroll {
                // 構成は変わらないがレイアウトが整った可能性。末尾スクロールを再試行する。
                DispatchQueue.main.async { [weak self] in self?.scrollToBottomIfNeeded() }
            }
        }

        private func applySnapshot(items: [Store.Item], grouping: PhotoGridGrouping?) {
            // 重い構築（id→index・グルーピング・snapshot 構築）は **オフメイン**で行い、メインでは
            // 反映（applySnapshotUsingReloadData）と参照テーブル代入のみ。68k で ~0.9s の UI 固まりを解消する。
            snapshotToken += 1
            let token = snapshotToken
            let t0 = CFAbsoluteTimeGetCurrent()
            Task.detached(priority: .userInitiated) { [weak self] in
                // --- オフメイン構築（純データのみ） ---
                var index: [Store.Item.ID: Int] = [:]
                index.reserveCapacity(items.count)
                for (i, item) in items.enumerated() { index[item.id] = i }

                var snapshot = NSDiffableDataSourceSnapshot<String, Store.Item.ID>()
                if let grouping {
                    // 月グループは「写真の少ない連続月」を範囲セクションへ束ねて行を密にする（列数非依存）。
                    let coalesce = grouping == .month ? gridCoalesceThreshold : 0
                    let sections = photoGridSections(items: items, grouping: grouping,
                                                     colCount: 1, coalesceBelow: coalesce)
                    var order: [String] = []
                    var idsByTitle: [String: [Store.Item.ID]] = [:]
                    for section in sections {
                        let ids = section.rows.flatMap { $0.entries.map { $0.item.id } }
                        if idsByTitle[section.title] == nil { order.append(section.title) }
                        idsByTitle[section.title, default: []].append(contentsOf: ids)
                    }
                    snapshot.appendSections(order)
                    for title in order { snapshot.appendItems(idsByTitle[title] ?? [], toSection: title) }
                } else {
                    snapshot.appendSections([""])   // dense：単一セクション（ヘッダなし）
                    snapshot.appendItems(items.map { $0.id }, toSection: "")
                }
                let buildMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                let sectionCount = snapshot.numberOfSections

                // --- メインで反映（古い世代は破棄） ---
                await MainActor.run { [weak self] in
                    guard let self, token == self.snapshotToken else { return }
                    self.items = items
                    self.idToIndex = index
                    self.dataSource.applySnapshotUsingReloadData(snapshot) { [weak self] in
                        let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                        Diagnostics.mark("grid.snapshot(bg): items=\(items.count) sections=\(sectionCount) "
                            + "build=\(Int(buildMs))ms total=\(Int(totalMs))ms")
                        DispatchQueue.main.async { self?.scrollToBottomIfNeeded() }
                    }
                }
            }
        }

        /// 初回のみ、タイムライン末尾（最新）へスクロールする。
        /// ⚠️ `layoutIfNeeded()`（全 ~22,500 行のセル属性を一括計算）は起動時の大スパイクになるため使わない。
        /// `scrollToItem(.bottom)` は対象付近だけを計算するので軽い（等間隔セルはオフセットを算術計算できる）。
        func scrollToBottomIfNeeded() {
            guard !didInitialScroll, let cv = collectionView, cv.bounds.height > 0 else { return }
            let lastSection = cv.numberOfSections - 1
            guard lastSection >= 0 else { return }
            let lastItem = cv.numberOfItems(inSection: lastSection) - 1
            guard lastItem >= 0 else { return }
            didInitialScroll = true
            cv.scrollToItem(at: IndexPath(item: lastItem, section: lastSection), at: .bottom, animated: false)
        }

        // MARK: Scroll / scrubber

        private func scrollTo(fraction: CGFloat) {
            guard let cv = collectionView else { return }
            let maxY = max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            cv.setContentOffset(CGPoint(x: 0, y: CGFloat(min(max(0, fraction), 1)) * maxY), animated: false)
        }

        private func cellPixelSize() -> CGSize {
            let cols = CGFloat(max(1, currentColumns))
            let width = collectionView?.bounds.width ?? UIScreen.main.bounds.width
            let side = max(1, (width - spacing * (cols - 1)) / cols)
            let scale = UIScreen.main.scale
            return CGSize(width: side * scale, height: side * scale)
        }

        // MARK: Gestures / delegate

        @objc private func handlePinch(_ gr: UIPinchGestureRecognizer) {
            guard gr.state == .ended else { return }
            onPinch(gr.scale)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.deselectItem(at: indexPath, animated: false)
            if let id = dataSource.itemIdentifier(for: indexPath) {
                onSelect(id)
            }
        }

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            let prefetch: [Store.Item] = indexPaths.compactMap { ip in
                guard let id = dataSource.itemIdentifier(for: ip),
                      let idx = idToIndex[id], idx < items.count else { return nil }
                return items[idx]
            }
            guard !prefetch.isEmpty else { return }
            store.prefetch(prefetch, targetSize: cellPixelSize())
        }

        // MARK: Scroll → 背景処理の一時停止（#3）
        // スクラブだけでなく**通常スクロール中**も背景 CLIP 埋め込みを譲り、操作を滑らかにする。

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            onScrubbingChange(true)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { onScrubbingChange(false) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            onScrubbingChange(false)
        }
    }
}
#endif
