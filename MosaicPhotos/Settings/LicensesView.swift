import SwiftUI

/// 設定「Licenses」画面：使用ライブラリ・資産と必要なライセンス表示。
/// 画面まわりの文言は日本語化し、ライセンス本文（`text`）は原文（英語）のまま表示する。
struct LicensesView: View {
    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        NavigationLink {
                            LicenseDetailView(item: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.role)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(item.license)
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if let footer = section.footer { Text(footer) }
                }
            }
        }
        .navigationTitle(L("Licenses"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // 言語切替に追従させるため body 評価時に L() で構築する。
    private var sections: [LicenseSection] {
        [
            LicenseSection(
                title: L("Bundled in the app"),
                footer: L("Third-party assets distributed with the app."),
                items: [
                    LicenseItem(
                        name: "MobileCLIP-S2",
                        role: L("On-device semantic search & display tags (Core ML model)"),
                        license: "Code: MIT · Weights: Apple ML Research Model License (research only)",
                        url: "https://github.com/apple/ml-mobileclip",
                        text: appleMobileCLIPNotice),
                    LicenseItem(
                        name: "OpenAI CLIP — BPE vocabulary",
                        role: L("Text tokenizer vocabulary (bpe_simple_vocab_16e6.txt)"),
                        license: "MIT",
                        url: "https://github.com/openai/CLIP",
                        text: mitLicenseText("Copyright (c) 2021 OpenAI")),
                    LicenseItem(
                        name: "CLIP / open_clip tokenizer",
                        role: L("BPE tokenizer algorithm, ported to Swift"),
                        license: "MIT",
                        url: "https://github.com/mlfoundations/open_clip",
                        text: mitLicenseText("Copyright (c) 2021 OpenCLIP authors (mlfoundations/open_clip)")),
                ]),

            LicenseSection(
                title: L("Apple"),
                footer: L("Provided under Apple's license terms (not open-source dependencies)."),
                items: [
                    LicenseItem(
                        name: "Apple SDKs & SF Symbols",
                        role: L("System frameworks and symbols"),
                        license: "© Apple Inc.",
                        url: nil,
                        text: appleFrameworksNotice),
                ]),

            LicenseSection(
                title: L("Build tools"),
                footer: L("Used only to build/convert the model. Not distributed in the app."),
                items: [
                    LicenseItem(
                        name: "coremltools",
                        role: L("Core ML model conversion"),
                        license: "BSD 3-Clause",
                        url: "https://github.com/apple/coremltools",
                        text: bsd3LicenseText("Copyright (c) 2017, Apple Inc.")),
                    LicenseItem(
                        name: "PyTorch",
                        role: L("Model export"),
                        license: "BSD 3-Clause",
                        url: "https://github.com/pytorch/pytorch",
                        text: pytorchLicenseText),
                    LicenseItem(
                        name: "open_clip",
                        role: L("Reference model & tokenizer"),
                        license: "MIT",
                        url: "https://github.com/mlfoundations/open_clip",
                        text: mitLicenseText("Copyright (c) 2021 OpenCLIP authors (mlfoundations/open_clip)")),
                    LicenseItem(
                        name: "apple/ml-mobileclip (Python)",
                        role: L("Model conversion package"),
                        license: "Apple ML license",
                        url: "https://github.com/apple/ml-mobileclip",
                        text: appleMobileCLIPNotice),
                    LicenseItem(
                        name: "Pillow (PIL)",
                        role: L("Image loading for evaluation"),
                        license: "HPND",
                        url: "https://github.com/python-pillow/Pillow",
                        text: pillowLicenseText),
                    LicenseItem(
                        name: "NumPy",
                        role: L("Numerical arrays for evaluation"),
                        license: "BSD 3-Clause",
                        url: "https://github.com/numpy/numpy",
                        text: bsd3LicenseText("Copyright (c) 2005-2024, NumPy Developers.")),
                ]),

            LicenseSection(
                title: L("Documentation"),
                footer: L("Used only by the design-note site, not in the app."),
                items: [
                    LicenseItem(
                        name: "Mermaid",
                        role: L("Diagrams in the architecture note"),
                        license: "MIT",
                        url: "https://github.com/mermaid-js/mermaid",
                        text: mitLicenseText("Copyright (c) 2014-2024 Knut Sveidqvist")),
                ]),
        ]
    }
}

/// ライセンス本文の詳細（スクロール表示＋ソースリンク）。
private struct LicenseDetailView: View {
    let item: LicenseItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let url = item.url, let link = URL(string: url) {
                    Link(destination: link) {
                        Label(url, systemImage: "link").font(.footnote)
                    }
                }
                Text(item.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
