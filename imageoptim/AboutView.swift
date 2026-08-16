//
//  AboutView.swift
//  ImageOptim
//
//  The About panel that used to be a window in ImageOptim.xib.
//

import SwiftUI

struct AboutView: View {
    @State private var credits = AttributedString()

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            Text(verbatim: "ImageOptim")
                .font(.title2.bold())
            Text(String(localized: "version \(version)", comment: "About window"))
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(credits)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 380)
        .task {
            guard credits.characters.isEmpty else { return }
            credits = Self.loadCredits()
        }
    }

    /// The localized Credits.html, with its hardcoded black text color dropped so that
    /// the system's label color (and therefore dark mode) wins.
    private static func loadCredits() -> AttributedString {
        guard let url = Bundle.main.url(forResource: "Credits", withExtension: "html"),
              let html = try? Data(contentsOf: url) else { return AttributedString() }

        let header = Data("""
        <!DOCTYPE html><meta charset=utf-8>
        <style>html,body {font:-apple-system-body; background: transparent; margin:0;}</style>
        <title>Credits</title>
        """.utf8)

        guard let attributed = try? NSAttributedString(
            data: header + html,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return AttributedString() }

        var result = AttributedString(attributed)
        for run in result.runs where run.link == nil {
            result[run.range].foregroundColor = nil
        }
        return result
    }
}
