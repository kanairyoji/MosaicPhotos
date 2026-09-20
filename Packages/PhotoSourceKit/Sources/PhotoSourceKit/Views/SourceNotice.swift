#if canImport(UIKit)
import SwiftUI

/// 写真の一覧の**上に出す知らせ**（ADR-202）。
///
/// ⚠️ ここは「見ている最中の人に、今すぐ伝えたいこと」専用。設定の案内や進捗は出さない
/// （出し始めると常時何かが出ていて、本当に伝えたいときに読まれなくなる）。
/// 現状の唯一の利用者は**オフロードの緊急停止**——クラウドのコピーが唯一だった写真が
/// 消えていた、という取り返しのつかない事実を伝えるため。
///
/// `PhotoSourceKit` は BackupKit を知らないので、文面も操作も**注入する側**が決める。
public struct SourceNotice: Equatable, Sendable {
    public let title: String
    public let message: String
    public let systemImage: String

    public init(title: String, message: String, systemImage: String = "exclamationmark.triangle.fill") {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }
}

public extension EnvironmentValues {
    /// 出す知らせ（nil＝出さない）。
    @Entry var sourceNotice: SourceNotice?
    /// 知らせを押したときの操作（設定画面を開く等）。
    @Entry var sourceNoticeAction: (@MainActor () -> Void)?
}

/// 知らせの帯（一覧の最上部）。押すと `sourceNoticeAction` を呼ぶ。
struct SourceNoticeBanner: View {
    let notice: SourceNotice
    let action: (@MainActor () -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.systemImage)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title).font(.subheadline.weight(.semibold))
                    Text(notice.message).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if action != nil {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityElement(children: .combine)
    }
}
#endif
