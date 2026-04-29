import SwiftUI

extension Text {
    init(markdown: String) {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: markdown, options: opts) {
            self.init(attr)
        } else {
            self.init(markdown)
        }
    }
}
