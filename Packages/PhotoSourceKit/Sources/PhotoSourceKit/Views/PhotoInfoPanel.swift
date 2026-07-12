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
                // 状態は常に表示（未処理／解析中／完了が分かるように）。
                statusRow(insight.status, hasSignals: insight.hasSignals)

                if insight.isScreenshot {
                    Label(L("Screenshot"), systemImage: "camera.viewfinder")
                        .font(.caption).foregroundStyle(.secondary)
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
                if let caption = insight.caption {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L("AI description"), systemImage: "text.below.photo")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(caption)
                            .font(.subheadline)
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
            Label(L("AI analysis: done"), systemImage: "sparkles")
                .font(.caption).foregroundStyle(.secondary)
        case .ready:
            Label(L("AI analysis"), systemImage: "sparkles")
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
