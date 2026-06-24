import DropboxKit
import SwiftUI

struct RootView: View {
    @State private var dropboxAuth = DropboxAuthService(
        appKey: DropboxKitTestConfig.appKey,
        redirectURI: DropboxKitTestConfig.redirectURI
    )
    @State private var useTabView = true

    var body: some View {
        if useTabView {
            TabView {
                SettingsScreen(dropboxAuth: dropboxAuth, useTabView: $useTabView)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                DebugRunnerView(dropboxAuth: dropboxAuth, useTabView: $useTabView)
                    .tabItem { Label("Debug", systemImage: "hammer") }
            }
        } else {
            NavigationStack {
                List {
                    NavigationLink {
                        SettingsScreen(dropboxAuth: dropboxAuth, useTabView: $useTabView)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    NavigationLink {
                        DebugRunnerView(dropboxAuth: dropboxAuth, useTabView: $useTabView)
                    } label: {
                        Label("Debug Runner", systemImage: "hammer")
                    }
                }
                .navigationTitle("DropboxKit Test")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        navToggleButton
                    }
                }
            }
        }
    }

    private var navToggleButton: some View {
        Button {
            useTabView.toggle()
        } label: {
            Image(systemName: useTabView ? "list.bullet" : "square.split.2x1")
        }
    }
}
