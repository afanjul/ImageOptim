//
//  AboutView.swift
//  ImageOptim
//
//  The About panel that used to be a window in ImageOptim.xib.
//

import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // The icon is centered in the window, the version sits at its bottom right, as in the nib
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .frame(maxWidth: .infinity)

                Text(verbatim: version)
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .textSelection(.enabled)
                    .accessibilityLabel(String(localized: "version", comment: "About window"))
                    .padding(.trailing, 11)
                    .padding(.bottom, 1)
            }
            .padding(.top, 15)

            CreditsView()
                .padding(.top, 17)
                .padding(.leading, 11)

            ForkNote()
                .padding(.top, 12)
                .padding(.horizontal, 11)
                .padding(.bottom, 12)
        }
        .frame(minWidth: 312, idealWidth: 312, maxWidth: 350,
               minHeight: 480, idealHeight: 515, maxHeight: 520)
    }
}

/// Says what this build is, since it isn't the official ImageOptim release
private struct ForkNote: View {
    // Not localized: it describes this particular fork, not the app
    private static let text: AttributedString = {
        let markdown = """
        Temporary build that runs reliably on macOS 26 (Apple Silicon). \
        It contains some of the code from \
        [ImageOptim PR #477](https://github.com/ImageOptim/ImageOptim/pull/477), \
        and ships without PNGOUT and without automatic updates.
        """
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }()

    var body: some View {
        Text(Self.text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// Credits.html in a text view, like the nib's: SwiftUI's `Text` drops the HTML's
/// paragraph styles (indents, list bullets, line height) and paints links itself.
private struct CreditsView: NSViewRepresentable {
    /// The text storage has to outlive `makeNSView`: a layout manager doesn't own it
    final class Coordinator {
        var textStorage: NSTextStorage?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        // The TextKit 1 stack is put together by hand because TextKit 2 lays out the
        // HTML's lists itself, drawing a second bullet and indent over the ones the
        // importer already wrote into the text
        let textStorage = NSTextStorage(attributedString: Self.credits())
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        context.coordinator.textStorage = textStorage

        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // The HTML's own underlines are kept, only the colour is left to the system
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}

    private static func credits() -> NSAttributedString {
        guard let url = Bundle.main.url(forResource: "Credits", withExtension: "html"),
              let html = try? Data(contentsOf: url) else { return NSAttributedString() }

        let header = Data("""
        <!DOCTYPE html><meta charset=utf-8>
        <style>html,body {font:11px/1.5 'Lucida Grande', sans-serif; color: #000; background: transparent; margin:0;}</style>
        <title>Credits</title>
        """.utf8)

        guard let credits = try? NSMutableAttributedString(
            data: header + html,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return NSAttributedString() }

        // The colours baked in by the HTML importer are fixed black and blue; swapping them
        // for the dynamic system colours is what makes the panel legible in dark mode
        let whole = NSRange(location: 0, length: credits.length)
        credits.enumerateAttribute(.link, in: whole) { link, range, _ in
            credits.addAttribute(.foregroundColor, value: link == nil ? NSColor.labelColor : NSColor.linkColor, range: range)
        }
        return credits
    }
}
