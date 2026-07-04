#if canImport(UIKit)
import UIKit

/// `PhotoCollectionView` のサムネイルセル。`UIImageView` を1枚持ち、`configure(loader:)` で
/// 非同期にサムネイルを読み込む。`prepareForReuse` でロードをキャンセルするため、高速スクロールで
/// 通り過ぎるセルは取得が走らない（出現直後に少し待ってから取得＝画像は後追い）。
final class GridThumbnailCell: UICollectionViewCell {
    private let imageView = UIImageView()
    /// お気に入り（端末写真）のとき左下に出す小さなハート。明暗どちらの写真でも視認できるよう
    /// 白＋影で描く（Apple 写真アプリと同様）。
    private let heartView = UIImageView()
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.clipsToBounds = true
        contentView.addSubview(imageView)

        heartView.image = UIImage(systemName: "heart.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        heartView.tintColor = .white
        heartView.contentMode = .scaleAspectFit
        heartView.translatesAutoresizingMaskIntoConstraints = false
        heartView.isHidden = true
        // 影で背景に溶けないようにする（白い写真の上でも見える）。
        heartView.layer.shadowColor = UIColor.black.cgColor
        heartView.layer.shadowOpacity = 0.6
        heartView.layer.shadowRadius = 1.5
        heartView.layer.shadowOffset = .zero
        contentView.addSubview(heartView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            heartView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            heartView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 2段階ロード：`stages` から届いた画像を順に差し替える（低解像度プレビュー → 最終画質）。
    /// 「まず何か見える」を優先し、後から高品質へ置き換わる（プログレッシブ表示）。
    func configure(isFavorite: Bool = false, stages: @escaping () -> AsyncStream<UIImage>) {
        heartView.isHidden = !isFavorite
        loadTask?.cancel()
        imageView.image = nil
        loadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return }
            for await image in stages() {
                if Task.isCancelled { return }
                imageView.image = image
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
        heartView.isHidden = true
    }
}
#endif
