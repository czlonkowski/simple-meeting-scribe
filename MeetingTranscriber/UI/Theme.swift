import SwiftUI

enum Theme {
    static let cornerRadius: CGFloat = 20
    static let innerPadding: CGFloat = 22
    static let accent: Color = .red
    static let subtle: Color = .primary.opacity(0.65)

    static let monoFont = Font.system(.body, design: .monospaced)
    static let titleFont = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let sectionTitleFont = Font.system(size: 15, weight: .medium, design: .rounded)
}

/// A card with Liquid Glass background. Deployment target is macOS 26,
/// so we can use `glassEffect` directly.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerRadius
    var padding: CGFloat = Theme.innerPadding
    let content: () -> Content

    init(cornerRadius: CGFloat = Theme.cornerRadius,
         padding: CGFloat = Theme.innerPadding,
         @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}
