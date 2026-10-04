import AppKit
import SwiftUI

extension View {
    /// A quick, compact tooltip (shown after ~0.3 s instead of the system's ~1 s), optionally with
    /// a keyboard shortcut. The text is also exposed to VoiceOver as the accessibility hint.
    func tip(_ text: String, shortcut: String? = nil) -> some View {
        modifier(TipModifier(text: text, shortcut: shortcut))
    }
}

private struct TipModifier: ViewModifier {
    let text: String
    let shortcut: String?
    /// Identifies this view's tooltip, so another view disappearing can't cancel it.
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    TooltipPresenter.shared.schedule(text, shortcut: shortcut, owner: owner)
                } else {
                    TooltipPresenter.shared.hide(owner: owner)
                }
            }
            .onDisappear { TooltipPresenter.shared.hide(owner: owner) }
            .accessibilityHint(text)
    }
}

/// One floating, non-activating panel shared by every tooltip. It works in the toolbar, status bar,
/// sidebar and sheets alike, where SwiftUI overlays would be clipped by their container.
@MainActor
final class TooltipPresenter {
    static let shared = TooltipPresenter()
    static let delay: TimeInterval = 0.3

    private let panel: NSPanel
    private let host = NSHostingView(rootView: TooltipLabel(text: "", shortcut: nil, width: 0))
    private var pending: DispatchWorkItem?
    /// The view whose tooltip is pending or showing.
    private var owner: UUID?
    private var clickMonitor: Any?
    /// When the last tooltip became visible (for tests and the smoke run).
    private(set) var shownAt: Date?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
        panel.contentView = host
        // Any click dismisses the tip, like the system's.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated { TooltipPresenter.shared.hide() }
            return event
        }
    }

    func schedule(_ text: String, shortcut: String?, owner: UUID = UUID()) {
        pending?.cancel()
        self.owner = owner
        let work = DispatchWorkItem { [weak self] in self?.show(text, shortcut: shortcut, at: NSEvent.mouseLocation) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func show(_ text: String, shortcut: String?, at mouse: NSPoint) {
        host.rootView = TooltipLabel(text: text, shortcut: shortcut, width: TooltipLabel.textWidth(text))
        let size = host.fittingSize
        // Below and slightly right of the pointer; above it near the bottom of the screen.
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x - 8, y: mouse.y - 24 - size.height)
        if origin.y < screen.minY { origin.y = mouse.y + 18 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        shownAt = Date()
    }

    /// Hides the tooltip if `owner` (when given) is the view it belongs to.
    func hide(owner: UUID? = nil) {
        if let owner, owner != self.owner { return }
        pending?.cancel()
        pending = nil
        self.owner = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                if self.panel.alphaValue == 0 { self.panel.orderOut(nil) }
            }
        }
    }

    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0 }
    var contentView: NSView { host }
}

/// The tooltip itself: a small dark rounded label with the shortcut in secondary text.
struct TooltipLabel: View {
    let text: String
    let shortcut: String?
    /// Width of the text column, measured up front: one line when it fits, else wrapped at
    /// `maxTextWidth`. A definite width lets the hosting view report the wrapped height.
    let width: CGFloat

    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let maxTextWidth: CGFloat = 260

    static func textWidth(_ text: String) -> CGFloat {
        min(maxTextWidth, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(Font(Self.font))
                .foregroundStyle(.white)
                .lineSpacing(1)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(white: 0.12).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        )
        .padding(8) // room for the shadow inside the panel
    }
}
