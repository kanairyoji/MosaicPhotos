#if canImport(UIKit)
import DropboxCore
import PhotoSourceKit
import SwiftUI

// MARK: - Debug section (Developer Options)

/// Dropbox の詳細診断：認証トークン・キャッシュ状態・消去/再同期・チューニング定数・直接トークン投入。
/// app の Developer Options 画面が合成して表示する（既定では非表示）。
/// 通常設定は `DropboxSettingsView` に分離している。
public struct DropboxDebugSection: View {
    let dropboxAuth: DropboxAuthService
    let store: DropboxPhotoStore?
    @State private var directTokenInput = ""
    @State private var cacheDebugModel = DropboxCacheDebugModel()
    @State private var showClearCacheConfirmation = false

    public init(dropboxAuth: DropboxAuthService, store: DropboxPhotoStore? = nil) {
        self.dropboxAuth = dropboxAuth
        self.store = store
    }

    public var body: some View {
        Group {
            authDebugSection
            cacheStatusSection
            tuningConstantsSection
        }
        .task { await cacheDebugModel.refresh(store: store) }
    }

    // MARK: - Auth debug

    private var authDebugSection: some View {
        Section {
            if let cred = dropboxAuth.credential {
                LabeledContent("アクセストークン", value: masked(cred.accessToken))
                LabeledContent("リフレッシュトークン", value: cred.refreshToken != nil ? "あり" : "なし")
                if let expiresAt = cred.expiresAt {
                    LabeledContent("有効期限", value: DisplayDate.dateTime(expiresAt))
                }
                if let lastRefreshed = cred.lastRefreshedAt {
                    LabeledContent("最終更新", value: DisplayDate.dateTime(lastRefreshed))
                }
                if let accountId = cred.accountId {
                    LabeledContent("アカウント ID", value: accountId)
                }
            }
            if case .error(let msg) = dropboxAuth.connectionStatus {
                LabeledContent("エラー詳細", value: msg)
                if let e = dropboxAuth.lastError {
                    LabeledContent("エラー日時", value: DisplayDate.dateTime(e.date))
                }
            }

            TextField("アクセストークンを直接入力", text: $directTokenInput)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("適用") {
                let token = directTokenInput.trimmingCharacters(in: .whitespaces)
                directTokenInput = ""
                Task {
                    await dropboxAuth.setDirectToken(token)
                }
            }
            .disabled(
                directTokenInput.trimmingCharacters(in: .whitespaces).isEmpty
                    || dropboxAuth.connectionStatus == .authenticating
            )
        } header: {
            Text("Dropbox：認証")
        } footer: {
            Text("Dropbox の認証トークンとエラー状態です。トークンを手動で貼り付けて適用することもできます"
                 + "（通常は不要・検証用）。トークンは先頭のみ表示します。")
        }
    }

    // MARK: - Cache status section

    private var cacheStatusSection: some View {
        Section {
            if let store {
                LabeledContent("同期", value: syncStateLabel(store.syncState))
            }
            if let s = cacheDebugModel.stats {
                LabeledContent("DB 内のファイル数", value: "\(s.itemCount)")
                LabeledContent("サムネイル", value: "\(s.thumbnailCount) · \(formatBytes(s.thumbnailBytes))")
                LabeledContent("フル画像", value: "\(s.fullImageCount) · \(formatBytes(s.fullImageBytes))")
                if let d = s.lastSyncedAt {
                    LabeledContent("最終同期", value: DisplayDate.dateTime(d))
                }
            } else {
                Text("未読み込み")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("更新") {
                    Task { await cacheDebugModel.refresh(store: store) }
                }
                Spacer()
                NavigationLink("キャッシュ内容を見る") {
                    DropboxCacheListView(model: cacheDebugModel, store: store)
                }
            }
            if let store {
                Button("強制的に再同期") { store.forceResync() }
            }
            Button("Dropbox キャッシュを消去", role: .destructive) {
                showClearCacheConfirmation = true
            }
            .alert("Dropbox キャッシュを消去しますか？", isPresented: $showClearCacheConfirmation) {
                Button("消去", role: .destructive) {
                    // 動作中ストア経由で消去＋再同期（cursor/syncState もリセット）→ 再取得。
                    Task { await cacheDebugModel.clearAll(store: store) }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("キャッシュしたメタデータとファイルをすべて削除します。この操作は取り消せません。")
            }
        } header: {
            Text("Dropbox：キャッシュの状態")
        } footer: {
            Text("同期状態と、ローカルにキャッシュしたファイル数／サムネ／フル画像の容量です。"
                 + "「強制的に再同期」はカーソルをリセットして最初から取得し直します。")
        }
    }

    // MARK: - Tuning constants (read-only)

    private var tuningConstantsSection: some View {
        Section {
            let c = DropboxDebugConstants.self
            LabeledContent("トークン更新の余裕", value: "\(c.tokenExpiryBufferSeconds) 秒")
            LabeledContent("サムネのバッチサイズ", value: "\(c.thumbnailBatchChunkSize)")
            LabeledContent("サムネのバッチ間引き", value: "\(c.thumbnailBatchDebounceMs) ms")
            LabeledContent("サムネの API サイズ", value: c.thumbnailAPISize)
            LabeledContent("list_folder の 1 ページ上限", value: "\(c.listFolderPageLimit)")
            LabeledContent("フォルダ走査の並列数", value: "\(c.parallelFolderScanBatchSize)")
            LabeledContent("longpoll のタイムアウト", value: "\(c.longpollTimeoutSeconds) 秒")
            LabeledContent("リトライ間隔", value: "\(c.retryDelaySeconds) 秒")
            LabeledContent("JPEG 品質（サムネ/フル）", value: "\(c.thumbnailJPEGQuality) / \(c.fullImageJPEGQuality)")
            LabeledContent("既定の上限（サムネ/フル）", value: "\(c.defaultThumbnailLimitMB) MB / \(c.defaultFullImageLimitMB) MB")
            LabeledContent("PKCE verifier のバイト数", value: "\(c.pkceVerifierByteCount)")
        } header: {
            Text("Dropbox：チューニング定数")
        } footer: {
            Text("同期・サムネ取得・認証まわりの内部定数（読み取り専用）です。")
        }
    }

    // MARK: - Helpers

    // formatBytes は PhotoSourceKit の共通ヘルパへ集約。

    private func masked(_ token: String) -> String {
        String(token.prefix(8)) + "..."
    }

    private func syncStateLabel(_ state: DropboxPhotoStore.SyncState) -> String {
        switch state {
        case .idle:                    return "待機中"
        case .initialSync(let n):      return "初回同期中 · \(n) 枚"
        case .polling:                 return "変更を監視中"
        case .fetchingDelta:           return "変更を取得中…"
        case .error(let msg):          return "エラー: \(msg)"
        }
    }
}
#endif
