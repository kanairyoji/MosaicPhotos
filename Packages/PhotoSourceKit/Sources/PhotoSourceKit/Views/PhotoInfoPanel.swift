#if canImport(UIKit)
import CoreLocation
import MapKit
import SwiftUI

/// 写真の詳細情報パネル（日付・場所・ファイル名・カメラ・撮影情報・地図・AI抽出情報）。
/// `FullPhotoView` の下部に、スクロールで可視化されたときに表示する。
struct PhotoInfoPanel: View {
    let captureDate: Date?
    let placeName: String?
    let coordinate: CLLocationCoordinate2D?
    let exif: PhotoExifInfo?
    let insight: PhotoInsight?
    /// 実体の所在（端末 / クラウド＋パス）。原因調査でまず要る情報なので常に出す。
    let sourceLocation: PhotoSourceLocation?

    /// 実体の所在。**「この写真はどこにあるのか」**を画面で答える。
    ///
    /// ⚠️ これが無いと「見覚えのない写真が一覧に出る」類の不具合を切り分けられない。
    /// 端末かクラウドか、クラウドならどのフォルダの何というファイルかが分かれば、
    /// 共有コピー・バックアップ・別フォルダのいずれ由来かがその場で判別できる。
    @ViewBuilder
    private var sourceSection: some View {
        if let sourceLocation {
            VStack(alignment: .leading, spacing: 6) {
                // ⚠️ 副題にフォルダを出さない。下のフルパスに含まれており、
                // **同じパスが 2 行に見える**（実装当初これをやって分かりにくかった）。
                header(systemImage: sourceLocation.kind == .cloud ? "cloud" : "iphone",
                       title: sourceLocation.kind == .cloud ? L("Cloud") : L("On this device"),
                       subtitle: nil)
                // パス/識別子は折り返して**全部**見せる（切ると肝心の所が読めない）。
                Text(sourceLocation.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)   // 長押しでコピーして報告に貼れる
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let captureDate {
                header(systemImage: "calendar",
                       title: DisplayDate.ymd(captureDate),
                       subtitle: captureDate.formatted(date: .omitted, time: .shortened))
            }
            if let placeName {
                header(systemImage: "mappin.and.ellipse",
                       title: placeName,
                       subtitle: coordinateText)
            }

            insightSection

            sourceSection

            VStack(alignment: .leading, spacing: 8) {
                detail(L("File"), exif?.fileName)
                detail(L("Camera"), cameraText)
                detail(L("Lens"), exif?.lensModel)
                detail(L("Exposure"), exposureText)
                detail(L("Dimensions"), dimensionsText)
            }

            if let coordinate {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate, latitudinalMeters: 1_500, longitudinalMeters: 1_500
                ))) {
                    Marker("", coordinate: coordinate)
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .allowsHitTesting(false)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: Insight (AI/Vision 抽出情報)

    @ViewBuilder
    private var insightSection: some View {
        if let insight {
            VStack(alignment: .leading, spacing: 12) {
                // 保存場所（端末 / Dropbox）→ 解析状態、の順に出す。
                if let source = insight.source { sourceRow(source) }
                statusRow(insight.status, hasSignals: insight.hasSignals)

                if insight.isScreenshot {
                    Label(L("Screenshot"), systemImage: "camera.viewfinder")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // バックアップ状態（端末写真のみ・クラウド写真は nil＝非表示）。
                if let backedUp = insight.isBackedUp {
                    if backedUp {
                        Label(L("Backed up to Dropbox"), systemImage: "checkmark.icloud")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Label(L("Not backed up"), systemImage: "icloud.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !insight.people.isEmpty {
                    header(systemImage: "person.2",
                           title: insight.people.joined(separator: ", "),
                           subtitle: peopleSubtitle)
                } else if let faceText = faceCountText {
                    // 名前は未設定でも「何人写っているか」は出す（顔スキャン済みのとき）。
                    header(systemImage: "person.crop.square",
                           title: faceText,
                           subtitle: L("Detected faces"))
                }
                // タグ欄は**常時表示**（付与前でも欄があることで「解析待ち」だと分かる）。
                VStack(alignment: .leading, spacing: 4) {
                    Label(L("Detected"), systemImage: "tag")
                        .font(.caption).foregroundStyle(.secondary)
                    if insight.tags.isEmpty {
                        Text(L("No tags yet — added automatically while charging"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(insight.tags.joined(separator: " · "))
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // 利用カウンタ（閲覧/共有/再生）。insight が取れた写真は常時表示（0 でも出す＝
                // 「数えている」ことが分かる）。再生は動画対応まで常に 0 なので >0 のときだけ。
                if let views = insight.viewCount {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("Activity"), systemImage: "chart.bar")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Label("\(views)", systemImage: "eye")
                            Label("\(insight.shareCount ?? 0)", systemImage: "square.and.arrow.up")
                            if let plays = insight.playCount, plays > 0 {
                                Label("\(plays)", systemImage: "play.circle")
                            }
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // 写真内テキスト（OCR・photo-info-expansion）。検出された写真だけ表示する。
                if let ocr = insight.ocrText, !ocr.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("Text in photo"), systemImage: "text.viewfinder")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(ocr)
                            .font(.subheadline)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else {
            // insight のロード完了前（closure が SwiftData/顔照会で少し遅い等）。
            // ここを空にすると「AI 解析欄が丸ごと消える」ので、必ずロード中を出す（空欄に見せない）。
            Label(L("AI analysis: loading…"), systemImage: "hourglass")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 解析状態の行。**意味のあるときだけ**出す（ADR-91）。
    /// 以前は解析済みで結果もあるとき「AI analysis」という見出しだけの行が出ていたが、
    /// 直下にタグ・人物・説明の各セクションが独自の見出しで並ぶため、情報がゼロだった
    /// （「横にも下にも何も出ていない」＝実フィードバック）。
    /// 残すのは「まだ解析していない／解析中／解析したが何も見つからなかった」の 3 つ。
    @ViewBuilder
    private func statusRow(_ status: PhotoInsight.Status, hasSignals: Bool) -> some View {
        switch status {
        case .notIndexed:
            Label(L("AI analysis: not indexed yet"), systemImage: "hourglass")
                .font(.caption).foregroundStyle(.secondary)
        case .analyzing:
            Label(L("AI analysis: in progress…"), systemImage: "hourglass.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .ready where !hasSignals:
            // 「終わったが何も検出されなかった」＝未解析と区別が付くようにはっきり書く。
            Label(L("AI analysis: nothing detected"), systemImage: "sparkles")
                .font(.caption).foregroundStyle(.secondary)
        case .ready:
            EmptyView()   // 結果は下の各セクションが語るので、見出しだけの行は出さない
        }
    }

    /// 保存場所（端末 / Dropbox）。同じ一覧に混在するので、どちらの写真かを明示する。
    @ViewBuilder
    private func sourceRow(_ source: PhotoInsight.Source) -> some View {
        switch source {
        case .local:
            Label(L("On this iPhone"), systemImage: "iphone")
                .font(.caption).foregroundStyle(.secondary)
        case .cloud:
            Label(L("In Dropbox"), systemImage: "cloud")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 人物名の下に出すサブタイトル。顔数が分かるときは「People · N faces」にする。
    private var peopleSubtitle: String {
        if let faceText = faceCountText { return "\(L("People")) · \(faceText)" }
        return L("People")
    }

    /// 「N faces / N face / No faces」。顔スキャン済み（faceCount != nil）のときだけ返す。
    private var faceCountText: String? {
        guard let n = insight?.faceCount else { return nil }
        switch n {
        case 0:  return L("No faces")
        case 1:  return L("1 face")
        default: return L("\(n) faces")
        }
    }

    // MARK: Rows

    private func header(systemImage: String, title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                Text(value).font(.caption).textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Formatting

    private var coordinateText: String? {
        guard let coordinate else { return nil }
        return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private var cameraText: String? {
        guard let model = exif?.cameraModel, !model.isEmpty else { return exif?.cameraMake }
        if let make = exif?.cameraMake, !make.isEmpty, !model.localizedCaseInsensitiveContains(make) {
            return "\(make) \(model)"
        }
        return model
    }

    private var dimensionsText: String? {
        guard let w = exif?.pixelWidth, let h = exif?.pixelHeight else { return nil }
        return "\(w) × \(h)"
    }

    private var exposureText: String? {
        guard let exif else { return nil }
        var parts: [String] = []
        if let f = exif.fNumber { parts.append("ƒ\(trimmed(f))") }
        if let t = exif.exposureTime {
            parts.append(t < 1 ? "1/\(Int((1 / t).rounded()))s" : "\(trimmed(t))s")
        }
        if let iso = exif.isoSpeed { parts.append("ISO \(iso)") }
        if let focal = exif.focalLength { parts.append("\(Int(focal.rounded()))mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
#endif
