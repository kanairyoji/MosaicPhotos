import Photos

/// 写真ライブラリの変更通知を受ける薄いラッパー（`NSObject` 必須）。
///
/// 変更の**内容**は見ない（`PHChange` の差分は fetch result を保持している場合にしか使えない）。
/// 「何か変わった」だけを伝え、購読側がデバウンスして再読み込み・索引の無効化を行う。
public final class PhotoLibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @Sendable () -> Void

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
