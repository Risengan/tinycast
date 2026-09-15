import SwiftUI

/// AppKit resolves the named base symbol directly, without SwiftUI inheriting a button variant.
struct MenuSymbolImage: View {
    let name: String
    let size: CGFloat

    var body: some View {
        if let image = MenuSymbolCache.image(named: name, size: size) {
            Image(nsImage: image)
                .renderingMode(.template)
                .frame(width: size, height: size)
        }
    }
}

/// Menu selection rebuilds the hosted tree; keep resolved monochrome symbols out of that hot path.
@MainActor
private enum MenuSymbolCache {
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    static func image(named name: String, size: CGFloat) -> NSImage? {
        let key = "\(name)|\(size)" as NSString
        if let image = images.object(forKey: key) { return image }
        let configuration = NSImage.SymbolConfiguration(
            pointSize: size, weight: Theme.Typography.menuSymbolNSWeight)
        guard
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

/// A bar control's hover chrome; footer pills and header pop-ups share `barControl` as one family.
enum BarButtonChrome {
    case capsule
    case rounded

    func shape(_ metrics: InterfaceMetrics) -> AnyShape {
        switch self {
        case .capsule:
            return AnyShape(Capsule())
        case .rounded:
            return AnyShape(
                RoundedRectangle(cornerRadius: metrics.radius.barControl, style: .continuous))
        }
    }
}

/// A palette bar control, bare until hover; hover lives here so its owner never re-renders.
struct BarButton<Label: View>: View {
    var chrome: BarButtonChrome = .capsule
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovered = false
    @Environment(\.metrics) private var metrics

    var body: some View {
        let shape = chrome.shape(metrics)
        return Button(action: action) {
            label
                .padding(.horizontal, metrics.spacing.md)
                .frame(height: metrics.size.barButtonHeight)
                .contentShape(shape)
                .background(shape.fill(hovered ? Theme.Colors.rowHover : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A header control that states the active choice and opens an in-window menu.
struct HeaderMenuButton: View {
    let title: String
    let icon: PopoverMenuIcon
    let isOpen: Bool
    let help: String
    let action: () -> Void
    @Environment(\.metrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String, icon: PopoverMenuIcon, isOpen: Bool, help: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isOpen = isOpen
        self.help = help
        self.action = action
    }

    init(
        title: String, systemImage: String, isOpen: Bool, help: String,
        action: @escaping () -> Void
    ) {
        self.init(title: title, icon: .symbol(systemImage), isOpen: isOpen, help: help, action: action)
    }

    var body: some View {
        BarButton(chrome: .rounded, action: action) {
            HStack(spacing: metrics.spacing.sm) {
                switch icon {
                case .blank:
                    EmptyView()
                case .symbol(let name):
                    MenuSymbolImage(
                        name: name, size: metrics.scaled(Theme.Typography.menuSymbolSize))
                case .asset(let name):
                    Image(name)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: metrics.size.barBrandIcon, height: metrics.size.barBrandIcon)
                case .file(let path):
                    MenuFileIcon(path: path)
                }
                Text(title)
                    .font(metrics.typography.bar)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // One fixed glyph rotates so opening the menu cannot change its layout.
                Image(systemName: "chevron.down")
                    .font(metrics.typography.disclosure)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .animation(
                        reduceMotion ? nil : Theme.MenuMotion.chevronAnimation,
                        value: isOpen)
            }
            .foregroundStyle(Theme.Colors.textSecondary)
        }
        .help(help)
    }
}
