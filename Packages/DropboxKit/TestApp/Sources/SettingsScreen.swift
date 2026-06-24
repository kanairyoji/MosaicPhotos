import DropboxKit
import SwiftUI

struct SettingsScreen: View {
    let dropboxAuth: DropboxAuthService
    @Binding var useTabView: Bool

    var body: some View {
        NavigationStack {
            Form {
                DropboxSettingsView(dropboxAuth: dropboxAuth)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        useTabView.toggle()
                    } label: {
                        Image(systemName: useTabView ? "list.bullet" : "square.split.2x1")
                    }
                }
            }
        }
    }
}
