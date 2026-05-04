import AppKit
import SwiftUI

struct ScrolliniMenuSnapshot {
    var workspaceIndex: Int
    var columnIndex: Int?
    var columnCount: Int
    var activeAppName: String
    var settingsPath: String
    var layoutStatePath: String?
    var layoutStateExists: Bool
    var transientSystemDialogActive: Bool
}

enum ScrolliniMenuMetrics {
    static let width: CGFloat = 260
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 6
}

@MainActor
protocol ScrolliniMenuItemMeasuring: AnyObject {
    func measuredHeight(width: CGFloat) -> CGFloat
}

@MainActor
final class ScrolliniMenuHostingView: NSView, ScrolliniMenuItemMeasuring {
    private let hostingController: NSHostingController<AnyView>
    private var cachedWidth: CGFloat?
    private var cachedHeight: CGFloat?

    override var allowsVibrancy: Bool {
        true
    }

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    init(rootView: AnyView, width: CGFloat = ScrolliniMenuMetrics.width) {
        hostingController = NSHostingController(rootView: rootView)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        configureHostingView(width: width)
        let height = measuredHeight(width: width)
        frame.size = NSSize(width: width, height: height)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        hostingController.view.frame = bounds
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        if cachedWidth == width, let cachedHeight {
            return cachedHeight
        }

        if frame.width != width || bounds.width != width {
            frame.size.width = width
            bounds.size.width = width
            hostingController.view.frame = bounds
            invalidateIntrinsicContentSize()
        }

        let proposed = NSSize(width: width, height: 600)
        let measured = hostingController.sizeThatFits(in: proposed)
        let rawHeight = measured.height.isFinite ? measured.height : hostingController.view.fittingSize.height
        let height = min(max(ceil(rawHeight), 1), 480)
        cachedWidth = width
        cachedHeight = height
        return height
    }

    private func configureHostingView(width: CGFloat) {
        hostingController.view.translatesAutoresizingMaskIntoConstraints = true
        hostingController.view.autoresizingMask = [.width, .height]
        hostingController.view.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        addSubview(hostingController.view)
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.minSize, .intrinsicContentSize]
        }
    }
}

@MainActor
enum ScrolliniMenuItemFactory {
    static func makeItem(for content: some View, enabled: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = enabled
        item.view = ScrolliniMenuHostingView(rootView: AnyView(content))
        return item
    }

    static func refreshViewHeights(in menu: NSMenu, width: CGFloat = ScrolliniMenuMetrics.width) {
        for item in menu.items {
            guard let view = item.view,
                  let measuring = view as? ScrolliniMenuItemMeasuring
            else {
                continue
            }

            let height = measuring.measuredHeight(width: width)
            if abs(view.frame.height - height) > 0.5 || abs(view.frame.width - width) > 0.5 {
                view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            }
        }
    }
}

struct ScrolliniMenuHeaderView: View {
    let snapshot: ScrolliniMenuSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("Scrollini")
                        .font(.subheadline.weight(.semibold))
                    Text(snapshot.transientSystemDialogActive ? "Paused" : "Running")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(activeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScrolliniMenuMetrics.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var activeSummary: String {
        if snapshot.columnCount == 0 {
            return "Workspace \(snapshot.workspaceIndex) has no tiled windows"
        }
        return "\(snapshot.activeAppName) - workspace \(snapshot.workspaceIndex), column \(snapshot.columnIndex ?? 0)"
    }
}

struct ScrolliniMenuDetailsView: View {
    let snapshot: ScrolliniMenuSnapshot

    var body: some View {
        VStack(spacing: 0) {
            ScrolliniMenuInfoRow(
                title: "Settings",
                subtitle: snapshot.settingsPath,
                systemImage: "gearshape"
            )
            ScrolliniMenuInfoRow(
                title: "Layout state",
                subtitle: layoutStateSummary,
                systemImage: snapshot.layoutStateExists ? "internaldrive" : "internaldrive.badge.questionmark"
            )
        }
        .padding(.vertical, 2)
    }

    private var layoutStateSummary: String {
        guard let layoutStatePath = snapshot.layoutStatePath else {
            return "disabled"
        }
        return layoutStatePath
    }
}

private struct ScrolliniMenuInfoRow: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScrolliniMenuMetrics.horizontalPadding)
        .padding(.vertical, 4)
    }
}

struct ScrolliniMenuBannerView: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScrolliniMenuMetrics.horizontalPadding)
        .padding(.vertical, 5)
    }
}

struct ScrolliniMenuDividerView: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.horizontal, ScrolliniMenuMetrics.horizontalPadding)
            .padding(.vertical, 4)
    }
}
