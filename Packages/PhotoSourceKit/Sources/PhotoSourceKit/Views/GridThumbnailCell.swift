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
    /// 顔ハイライト（人物アルバムの「顔を表示」トグル中のみ）。単位座標（原点左上）を黄枠で描く。
    private let faceLayer = CAShapeLayer()
    private var faceRects: [CGRect] = []
    private var faceTask: Task<Void, Never>?

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

        faceLayer.strokeColor = UIColor.systemYellow.cgColor
        faceLayer.fillColor = nil
        faceLayer.lineWidth = 1.5
        contentView.layer.addSublayer(faceLayer)

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

    /// 顔ハイライトの設定。nil で消去、クロージャで単位座標矩形（原点左上）を非同期取得して描く。
    func setFaceBoxes(_ load: (() async -> [CGRect])?) {
        faceTask?.cancel()
        faceRects = []
        faceLayer.path = nil
        guard let load else { return }
        faceTask = Task { @MainActor in
            let rects = await load()
            if Task.isCancelled { return }
            faceRects = rects
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        faceLayer.frame = contentView.bounds
        if faceRects.isEmpty {
            faceLayer.path = nil
        } else {
            let w = contentView.bounds.width
            let h = contentView.bounds.height
            let path = CGMutablePath()
            for r in faceRects {
                let rect = CGRect(x: r.origin.x * w, y: r.origin.y * h,
                                  width: r.width * w, height: r.height * h)
                let corner = min(3, rect.width / 2, rect.height / 2)
                path.addRoundedRect(in: rect, cornerWidth: corner, cornerHeight: corner)
            }
            faceLayer.path = path
        }
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
        heartView.isHidden = true
        faceTask?.cancel()
        faceTask = nil
        faceRects = []
        faceLayer.path = nil
    }
}
#endif
