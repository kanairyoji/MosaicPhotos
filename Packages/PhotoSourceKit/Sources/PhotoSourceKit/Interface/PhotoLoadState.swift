/// Unified loading / permission state shared across photo sources.
public enum PhotoLoadState: Equatable {
    /// Not yet started. Triggers `start()` on first appearance.
    case idle
    /// Cannot load — permission denied or not connected.
    /// `systemImage` is the SF Symbol shown in the placeholder.
    case needsSetup(message: String, detail: String?, systemImage: String)
    /// Loading in progress.
    case loading
    /// Items loaded and available.
    case loaded
    /// Load succeeded but returned zero items.
    case empty
    /// Load failed with an error message.
    case failed(String)
}
