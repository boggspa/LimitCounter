import Combine
import SwiftUI

// MARK: - Drag-to-reorder for the dashboard's stacks

/// Runs drag-to-reorder for one vertical stack of dashboard items: provider
/// cards, provider blocks, or the meter rows inside one block or period.
///
/// Items are dragged by a grip, never by their whole surface, so a click or
/// a scroll can't start a move by accident. While a drag is under way a
/// phantom of the item follows the pointer, the item itself fades where it
/// stands, and a divider marks the gap it will land in. Letting go drops it
/// exactly there; with no divider showing, letting go changes nothing.
@MainActor
final class ReorderController: ObservableObject {
    /// The item being dragged. Published on its own so the items only
    /// redraw when a drag starts or ends, not on every pointer move.
    @Published private(set) var draggedKey: String?

    /// The pointer and landing gap, which change continuously.
    let tracker = ReorderTracker()

    /// The stack's items in the order they show.
    var order: [String] = []
    /// Called with the dragged item and the gap it landed in, counted among
    /// the other items (0 is before the first).
    var onMove: (_ key: String, _ gap: Int) -> Void = { _, _ in }
    /// Scrolls the enclosing scroll view while the pointer nears its edge.
    weak var autoscroller: ReorderAutoscroller?

    /// Each item's frame, in global coordinates.
    private var frames: [String: CGRect] = [:]

    func updateFrames(_ newFrames: [String: CGRect]) {
        frames = newFrames
        // The pointer can sit still while the content scrolls under it.
        if let key = draggedKey, let drag = tracker.drag {
            tracker.update(pointer: drag.pointer, gap: gap(for: key, at: drag.pointer))
        }
    }

    func begin(_ key: String, at pointer: CGPoint) {
        guard draggedKey == nil, let frame = frames[key] else { return }
        draggedKey = key
        tracker.start(
            ReorderDrag(
                key: key,
                pointer: pointer,
                grabOffsetY: pointer.y - frame.minY,
                itemFrame: frame,
                gap: nil
            )
        )
    }

    func drag(to pointer: CGPoint) {
        guard let key = draggedKey else { return }
        tracker.update(pointer: pointer, gap: gap(for: key, at: pointer))
        autoscroller?.steer(pointerY: pointer.y)
    }

    func end() {
        autoscroller?.stop()
        guard let key = draggedKey else { return }
        let gap = tracker.drag?.gap
        draggedKey = nil
        tracker.clear()
        if let gap {
            withAnimation(.snappy(duration: 0.24)) {
                onMove(key, gap)
            }
        }
    }

    func cancel() {
        autoscroller?.stop()
        draggedKey = nil
        tracker.clear()
    }

    /// Moves an item one place up or down, for VoiceOver and keyboard users.
    func nudge(_ key: String, by offset: Int) {
        guard let index = order.firstIndex(of: key) else { return }
        let gap = index + offset
        guard gap >= 0, gap < order.count, gap != index else { return }
        withAnimation(.snappy(duration: 0.24)) {
            onMove(key, gap)
        }
    }

    /// Where the divider goes for the current gap: a horizontal line in
    /// global coordinates, or `nil` when no gap is marked.
    func dividerLine() -> (y: CGFloat, minX: CGFloat, maxX: CGFloat)? {
        guard let key = draggedKey, let gap = tracker.drag?.gap else { return nil }
        let others = order.filter { $0 != key }
        let placed = others.compactMap { frames[$0] }
        guard let first = placed.first else { return nil }
        let minX = placed.map(\.minX).min() ?? first.minX
        let maxX = placed.map(\.maxX).max() ?? first.maxX

        let y: CGFloat
        if gap <= 0 {
            guard let below = frames[others[0]] else { return nil }
            y = below.minY - Self.edgeInset(above: nil, below: below, frames: placed)
        } else if gap >= others.count {
            guard let above = others.last.flatMap({ frames[$0] }) else { return nil }
            y = above.maxY + Self.edgeInset(above: above, below: nil, frames: placed)
        } else {
            guard let above = frames[others[gap - 1]], let below = frames[others[gap]] else { return nil }
            y = (above.maxY + below.minY) / 2
        }
        return (y, minX, maxX)
    }

    /// The gap a drop at `pointer` lands in, or `nil` when it would leave
    /// the order as it is or the pointer has wandered off the stack.
    private func gap(for key: String, at pointer: CGPoint) -> Int? {
        let others = order.filter { $0 != key }
        let placed = others.enumerated().compactMap { index, other in
            frames[other].map { (index: index, frame: $0) }
        }
        guard let first = placed.first, let last = placed.last else { return nil }

        let bounds = placed.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        guard bounds.insetBy(dx: -Self.tolerance, dy: -Self.tolerance).contains(pointer) else {
            return nil
        }

        // The first item whose middle is still below the pointer. Items a
        // lazy stack has not laid out sit beyond the realised ones.
        let gap = placed.first { $0.frame.midY > pointer.y }?.index ?? (last.index + 1)
        let original = order.firstIndex(of: key) ?? gap
        return gap == original ? nil : gap
    }

    /// How far outside the stack the pointer may stray before a drop there
    /// means "put it back".
    private static let tolerance: CGFloat = 36

    /// Half the stack's spacing, so the divider at either end sits as far
    /// out as the ones between items.
    private static func edgeInset(above: CGRect?, below: CGRect?, frames: [CGRect]) -> CGFloat {
        let sorted = frames.sorted { $0.minY < $1.minY }
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.minY - $0.maxY }.filter { $0 > 0 }
        return (gaps.min() ?? 8) / 2
    }
}

/// A drag in progress.
struct ReorderDrag: Equatable {
    let key: String
    /// The pointer, in global coordinates.
    var pointer: CGPoint
    /// How far below the item's top edge it was picked up, so the phantom
    /// keeps that grip.
    let grabOffsetY: CGFloat
    /// The item's frame when it was picked up, in global coordinates.
    let itemFrame: CGRect
    /// The gap it would land in among the other items, if any.
    var gap: Int?
}

/// The fast-changing half of a drag, watched only by the overlay that draws
/// the phantom and the divider.
@MainActor
final class ReorderTracker: ObservableObject {
    @Published private(set) var drag: ReorderDrag?

    fileprivate func start(_ drag: ReorderDrag) {
        self.drag = drag
    }

    fileprivate func update(pointer: CGPoint, gap: Int?) {
        guard var drag else { return }
        drag.pointer = pointer
        guard drag != self.drag || drag.gap != gap else { return }
        let gapChanged = drag.gap != gap
        drag.gap = gap
        if gapChanged {
            withAnimation(.easeOut(duration: 0.12)) { self.drag = drag }
        } else {
            self.drag = drag
        }
    }

    fileprivate func clear() {
        drag = nil
    }
}

// MARK: - Grip

/// The handle an item is dragged by. Hovering shows the grab cursor on the
/// Mac; VoiceOver users get "Move up" and "Move down" actions instead.
struct ReorderGrip: View {
    enum Style {
        /// Three short lines beside a meter row or block header.
        case lines
        /// A small bar across the top edge of a card.
        case bar
    }

    let key: String
    let label: String
    let style: Style
    @ObservedObject var controller: ReorderController

    @GestureState private var isPressing = false
    @State private var isHovering = false

    #if os(iOS)
    static let lineSlot = CGSize(width: 22, height: 18)
    static let lineTouchArea = CGSize(width: 44, height: 32)
    #else
    static let lineSlot = CGSize(width: 15, height: 18)
    static let lineTouchArea = lineSlot
    #endif

    private var isDragging: Bool { controller.draggedKey == key }

    var body: some View {
        handle
            #if os(macOS)
            .onHover { isHovering = $0 }
            .pointerStyle(isDragging ? .grabActive : .grabIdle)
            #endif
            .highPriorityGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .updating($isPressing) { _, state, _ in state = true }
                    .onChanged { value in
                        if controller.draggedKey == nil {
                            controller.begin(key, at: value.startLocation)
                        }
                        controller.drag(to: value.location)
                    }
                    .onEnded { _ in controller.end() }
            )
            // A gesture the system cancels never reaches `onEnded`; its
            // state resetting is the only sign, so put everything back.
            .onChange(of: isPressing) { _, pressing in
                if !pressing, controller.draggedKey == key {
                    controller.cancel()
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Reorder \(label)")
            .accessibilityHint("Drag to move it, or use the Move up and Move down actions.")
            .accessibilityAction(named: "Move up") { controller.nudge(key, by: -1) }
            .accessibilityAction(named: "Move down") { controller.nudge(key, by: 1) }
    }

    @ViewBuilder
    private var handle: some View {
        switch style {
        case .lines:
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Self.lineSlot.width, height: Self.lineSlot.height)
                .contentShape(
                    Rectangle()
                        .size(Self.lineTouchArea)
                        .offset(
                            x: (Self.lineSlot.width - Self.lineTouchArea.width) / 2,
                            y: (Self.lineSlot.height - Self.lineTouchArea.height) / 2
                        )
                )
        case .bar:
            Capsule(style: .continuous)
                .fill(tint)
                .frame(width: isHovering || isDragging ? 40 : 30, height: 4)
                .frame(width: 72, height: 14)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }

    private var tint: Color {
        if isDragging { return .primary }
        return Color.secondary.opacity(isHovering ? 0.95 : 0.55)
    }
}

// MARK: - Stack and item plumbing

private struct ReorderFramesPreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ReorderItemModifier: ViewModifier {
    let key: String
    @ObservedObject var controller: ReorderController

    func body(content: Content) -> some View {
        content
            // The item stays in place, faded, as the slot it is leaving.
            .opacity(controller.draggedKey == key ? 0.3 : 1)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ReorderFramesPreference.self,
                        value: [key: geometry.frame(in: .global)]
                    )
                }
            }
    }
}

private struct ReorderStackModifier<Phantom: View>: ViewModifier {
    @ObservedObject var controller: ReorderController
    let order: [String]
    let accent: (String) -> Color
    let onMove: (_ key: String, _ gap: Int) -> Void
    let phantom: (String) -> Phantom
    @Environment(\.reorderAutoscroller) private var autoscroller

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ReorderFramesPreference.self) { frames in
                MainActor.assumeIsolated { controller.updateFrames(frames) }
            }
            // A nested stack's rows are its own business, not its parent's.
            .transformPreference(ReorderFramesPreference.self) { $0 = [:] }
            .overlay {
                ReorderOverlay(
                    controller: controller,
                    tracker: controller.tracker,
                    accent: accent,
                    phantom: phantom
                )
            }
            .onAppear { configure() }
            .onChange(of: order) { _, _ in configure() }
    }

    private func configure() {
        controller.order = order
        controller.onMove = onMove
        controller.autoscroller = autoscroller
    }
}

/// Draws the phantom and the divider above the stack. It never takes hits:
/// the grip keeps the gesture for the whole drag.
private struct ReorderOverlay<Phantom: View>: View {
    let controller: ReorderController
    @ObservedObject var tracker: ReorderTracker
    let accent: (String) -> Color
    let phantom: (String) -> Phantom

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            if let drag = tracker.drag {
                let tint = accent(drag.key)
                phantom(drag.key)
                    .frame(width: drag.itemFrame.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(1.02)
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                    // Faint while letting go would change nothing.
                    .opacity(drag.gap == nil ? 0.55 : 0.94)
                    // Follows the pointer up and down its own column.
                    .offset(
                        x: drag.itemFrame.minX - origin.x,
                        y: drag.pointer.y - drag.grabOffsetY - origin.y
                    )
                // Drawn over the phantom, which usually sits right on the gap.
                if let line = controller.dividerLine() {
                    ReorderDivider(tint: tint)
                        .frame(width: max(line.maxX - line.minX, 0) + 6, height: 8)
                        .position(x: (line.minX + line.maxX) / 2 - origin.x, y: line.y - origin.y)
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The insertion mark: a bright line with a dot at each end.
private struct ReorderDivider: View {
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(tint, lineWidth: 2).frame(width: 8, height: 8)
            Capsule(style: .continuous).fill(tint).frame(height: 3)
            Circle().strokeBorder(tint, lineWidth: 2).frame(width: 8, height: 8)
        }
        .shadow(color: tint.opacity(0.7), radius: 5)
    }
}

extension View {
    /// Marks a view as one item of a reorderable stack.
    func reorderItem(_ key: String, controller: ReorderController) -> some View {
        modifier(ReorderItemModifier(key: key, controller: controller))
    }

    /// Makes a stack reorderable. `order` is the items' keys as they show;
    /// `onMove` gets the dragged key and the gap it landed in among the
    /// other items; `phantom` draws what follows the pointer.
    func reorderStack<Phantom: View>(
        controller: ReorderController,
        order: [String],
        accent: @escaping (String) -> Color,
        onMove: @escaping (_ key: String, _ gap: Int) -> Void,
        @ViewBuilder phantom: @escaping (String) -> Phantom
    ) -> some View {
        modifier(
            ReorderStackModifier(
                controller: controller,
                order: order,
                accent: accent,
                onMove: onMove,
                phantom: phantom
            )
        )
    }
}

/// A stack that owns its own controller: the meter rows of one block or one
/// period section.
struct ReorderableStack<Item, Row: View, Phantom: View>: View {
    let items: [Item]
    let key: (Item) -> String
    var spacing: CGFloat = 6
    let accent: (Item) -> Color
    let onMove: (_ key: String, _ gap: Int) -> Void
    @ViewBuilder let row: (Item, ReorderController) -> Row
    @ViewBuilder let phantom: (Item) -> Phantom

    @StateObject private var controller = ReorderController()

    var body: some View {
        let keyed = items.map { KeyedItem(id: key($0), item: $0) }
        let byKey = Dictionary(keyed.map { ($0.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(keyed) { entry in
                row(entry.item, controller)
                    .reorderItem(entry.id, controller: controller)
            }
        }
        .reorderStack(
            controller: controller,
            order: keyed.map(\.id),
            accent: { byKey[$0].map(accent) ?? ProGlassTheme.accent },
            onMove: onMove,
            phantom: { key in
                if let item = byKey[key] {
                    phantom(item)
                }
            }
        )
    }

    private struct KeyedItem: Identifiable {
        let id: String
        let item: Item
    }
}

/// The look shared by card and block phantoms: the provider and account
/// being moved, on a raised glass chip.
struct ReorderPhantomChip: View {
    let providerID: ProviderID
    let title: String

    var body: some View {
        let accent = Color(hex: providerID.accentColorHex)
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            ProviderBrandIconView(providerID: providerID, size: 18)
                .frame(width: 22, height: 22)
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.65), lineWidth: 1.2)
        }
    }
}

/// The grip as a phantom shows it: the lines, without the gesture.
struct ReorderGripGlyph: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: ReorderGrip.lineSlot.width, height: ReorderGrip.lineSlot.height)
    }
}

/// A meter row lifted out of its stack.
struct ReorderPhantomRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
    }
}

// MARK: - Auto-scroll

/// Scrolls the dashboard while a dragged item nears the top or bottom of
/// the visible area, so a card can travel the whole list in one drag.
@MainActor
final class ReorderAutoscroller: ObservableObject {
    /// The scroll view's visible frame, in global coordinates.
    var viewport: CGRect = .zero
    var contentOffset: CGFloat = 0
    var offsetRange: ClosedRange<CGFloat> = 0...0
    /// The offset the scroll view should move to next.
    @Published private(set) var requestedOffset: CGFloat?

    /// How close to an edge the pointer must come, and the fastest scroll.
    private static let edgeBand: CGFloat = 56
    private static let maximumSpeed: CGFloat = 900

    private var velocity: CGFloat = 0
    private var ticker: Task<Void, Never>?

    func steer(pointerY: CGFloat) {
        guard viewport.height > Self.edgeBand * 3 else { return stop() }
        let top = viewport.minY + Self.edgeBand
        let bottom = viewport.maxY - Self.edgeBand
        if pointerY < top {
            velocity = -Self.speed(depth: top - pointerY)
        } else if pointerY > bottom {
            velocity = Self.speed(depth: pointerY - bottom)
        } else {
            velocity = 0
        }
        if velocity == 0 {
            stop()
        } else if ticker == nil {
            startTicking()
        }
    }

    func stop() {
        velocity = 0
        ticker?.cancel()
        ticker = nil
    }

    private static func speed(depth: CGFloat) -> CGFloat {
        min(max(depth, 0), edgeBand) / edgeBand * maximumSpeed
    }

    private func startTicking() {
        ticker = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.velocity != 0 else { return }
                let now = ContinuousClock.now
                let elapsed = now - last
                last = now
                let seconds = CGFloat(elapsed.components.seconds)
                    + CGFloat(elapsed.components.attoseconds) / 1e18
                let target = min(
                    max(self.contentOffset + self.velocity * seconds, self.offsetRange.lowerBound),
                    self.offsetRange.upperBound
                )
                guard target != self.contentOffset else { continue }
                self.contentOffset = target
                self.requestedOffset = target
            }
        }
    }
}

private struct ReorderAutoscrollerKey: EnvironmentKey {
    static let defaultValue: ReorderAutoscroller? = nil
}

extension EnvironmentValues {
    var reorderAutoscroller: ReorderAutoscroller? {
        get { self[ReorderAutoscrollerKey.self] }
        set { self[ReorderAutoscrollerKey.self] = newValue }
    }
}

extension View {
    /// Lets reorder drags inside this scroll view scroll it. Needs iOS 18 or
    /// macOS 15 to steer the scroll position; earlier systems only reorder
    /// within what is on screen.
    func reorderAutoscroll(_ autoscroller: ReorderAutoscroller) -> some View {
        modifier(ReorderAutoscrollModifier(autoscroller: autoscroller))
    }
}

private struct ReorderAutoscrollModifier: ViewModifier {
    let autoscroller: ReorderAutoscroller

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.modifier(ReorderAutoscrollBridge(autoscroller: autoscroller))
        } else {
            content.environment(\.reorderAutoscroller, nil)
        }
    }
}

@available(iOS 18.0, macOS 15.0, *)
private struct ReorderAutoscrollBridge: ViewModifier {
    @ObservedObject var autoscroller: ReorderAutoscroller
    @State private var position = ScrollPosition(edge: .top)

    private struct Metrics: Equatable {
        let offset: CGFloat
        let range: ClosedRange<CGFloat>
    }

    func body(content: Content) -> some View {
        content
            .environment(\.reorderAutoscroller, autoscroller)
            .scrollPosition($position)
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                let lowest = -geometry.contentInsets.top
                let highest = max(
                    geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom,
                    lowest
                )
                return Metrics(offset: geometry.contentOffset.y, range: lowest...highest)
            } action: { _, metrics in
                autoscroller.contentOffset = metrics.offset
                autoscroller.offsetRange = metrics.range
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                autoscroller.viewport = frame
            }
            .onChange(of: autoscroller.requestedOffset) { _, offset in
                guard let offset else { return }
                position.scrollTo(y: offset)
            }
    }
}
