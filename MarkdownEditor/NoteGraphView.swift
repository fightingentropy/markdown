import AppKit
import SwiftUI

struct NoteGraphView: View {
    @Bindable var workspace: Workspace

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var layout = NoteGraphLayout.empty
    @State private var layoutTask: Task<Void, Never>?
    @State private var relayoutSeed = 0
    @State private var viewport = GraphViewport()
    @State private var hoveredNodeID: URL?
    @State private var isComputingLayout = false
    @State private var filter = GraphFilter()
    @State private var isFilterBarPresented = false
    /// Topology identity of the layout most recently scheduled, used to avoid
    /// re-running the force simulation on cosmetic (filter/selection) changes.
    @State private var laidOutTopology: GraphTopologyKey?

    private let minimumZoom: CGFloat = 0.65
    private let maximumZoom: CGFloat = 2.8

    private var rawSnapshot: NoteGraphSnapshot {
        workspace.noteGraph
    }

    /// Snapshot the force layout is computed from. We lay out the *unfiltered*
    /// topology (plus the current selection, which is pinned to center) so that
    /// cosmetic filter changes never trigger a relayout — filtered-out nodes are
    /// simply not drawn. See `scheduleLayout`.
    private var layoutSnapshot: NoteGraphSnapshot {
        rawSnapshot
    }

    /// Graph snapshot with active filters applied. Edges are trimmed to only
    /// those whose endpoints both survived the filter so orphan edges don't
    /// get drawn.
    private var snapshot: NoteGraphSnapshot {
        let base = rawSnapshot
        guard !filter.isEmpty else { return base }

        let searchQuery = filter.titleSearch.trimmingCharacters(in: .whitespacesAndNewlines)

        let allowedIDs = Set(base.nodes.compactMap { node -> URL? in
            guard node.degree >= filter.minDegree else { return nil }

            if !searchQuery.isEmpty,
               !node.title.localizedStandardContains(searchQuery),
               !node.relativePath.localizedStandardContains(searchQuery) {
                return nil
            }

            return node.id
        })

        let filteredNodes = base.nodes.filter { allowedIDs.contains($0.id) }
        let filteredEdges = base.edges.filter {
            allowedIDs.contains($0.source) && allowedIDs.contains($0.target)
        }
        let filteredSelected = base.selectedNodeID.flatMap { allowedIDs.contains($0) ? $0 : nil }
        let filteredConnected = base.connectedNodeIDs.intersection(allowedIDs)

        return NoteGraphSnapshot(
            nodes: filteredNodes,
            edges: filteredEdges,
            selectedNodeID: filteredSelected,
            connectedNodeIDs: filteredConnected
        )
    }

    private var visibleLabelNodeIDs: Set<URL> {
        var ids = Set<URL>()

        if let selectedNodeID = snapshot.selectedNodeID {
            ids.insert(selectedNodeID)
            let neighborIDs = snapshot.neighbors(of: selectedNodeID)
                .prefix(6)
                .map(\.id)
            ids.formUnion(neighborIDs)
        }

        if let hoveredNodeID {
            ids.insert(hoveredNodeID)
        }

        let prominentNodes = snapshot.nodes
            .sorted { lhs, rhs in
                if lhs.degree != rhs.degree {
                    return lhs.degree > rhs.degree
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(4)
            .map(\.id)
        ids.formUnion(prominentNodes)

        return ids
    }

    private var connectedNodes: [NoteGraphNode] {
        snapshot.neighbors(of: snapshot.selectedNodeID)
    }

    /// Identity of the inputs that actually require a fresh force layout: the raw
    /// node/edge topology, the pinned (selected) node, and the relayout seed.
    /// Filter search text and min-degree are intentionally excluded so typing in
    /// the filter does not relayout or reshuffle the graph.
    private var layoutTopologyKey: GraphTopologyKey {
        GraphTopologyKey(
            nodeIDs: layoutSnapshot.nodes.map(\.id),
            edgeIDs: layoutSnapshot.edges.map(\.id),
            selectedNodeID: layoutSnapshot.selectedNodeID,
            relayoutSeed: relayoutSeed
        )
    }

    /// Whether the force simulation should be skipped this scheduling pass because
    /// only the pinned node changed and the existing positions can be re-centered.
    private func canRecenterOnly(for key: GraphTopologyKey) -> Bool {
        guard let previous = laidOutTopology else { return false }
        return previous.nodeIDs == key.nodeIDs
            && previous.edgeIDs == key.edgeIDs
            && previous.relayoutSeed == key.relayoutSeed
            && previous.selectedNodeID != key.selectedNodeID
    }

    var body: some View {
        Group {
            if rawSnapshot.nodes.isEmpty {
                ContentUnavailableView(
                    "No Graph Yet",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Create notes and connect them with `[[Wiki Links]]` or local markdown links to map the vault.")
                )
            } else {
                GeometryReader { geometry in
                    ZStack {
                        graphBackdrop

                        graphCanvas(in: geometry.size)

                        if let selectedNode = snapshot.selectedNode {
                            selectedNodePanel(selectedNode)
                                .padding(20)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }

                        controlsPanel
                            .padding(20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                        if snapshot.nodes.isEmpty {
                            noMatchesOverlay
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if !connectedNodes.isEmpty {
                            relatedNotesPanel
                                .padding(20)
                        }
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(panGesture)
                    .simultaneousGesture(magnificationGesture)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            scheduleLayout()
        }
        .onDisappear {
            layoutTask?.cancel()
        }
        .onChange(of: layoutTopologyKey) { _, _ in
            scheduleLayout()
        }
        .onChange(of: snapshot.selectedNodeID) { oldValue, newValue in
            if oldValue != newValue {
                resetViewport()
            }
        }
    }

    private var noMatchesOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No matches")
                .font(.headline)
            Text("No notes match the current filter.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Clear Filter") { filter = GraphFilter() }
                .controlSize(.regular)
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
    }

    private var graphBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .textBackgroundColor),
                    Color.accentColor.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.08),
                    .clear
                ],
                center: .center,
                startRadius: 20,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    private func graphCanvas(in size: CGSize) -> some View {
        ZStack {
            Canvas { context, canvasSize in
                drawEdges(in: &context, size: canvasSize)
                drawNodes(in: &context, size: canvasSize)
            }
            .allowsHitTesting(false)

            ForEach(labeledNodes) { node in
                if let position = layout.positions[node.id] {
                    nodeLabel(node, position: transformed(position, in: size))
                }
            }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleNodeTap(at: location, in: size)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredNodeID = nearestNode(to: location, in: size)?.id
                    case .ended:
                        hoveredNodeID = nil
                    }
                }
                .allowsHitTesting(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note graph")
        .accessibilityRepresentation {
            accessibilityNodeList
        }
    }

    /// A focusable, VoiceOver-navigable representation of the graph nodes layered
    /// over the Canvas rendering (which itself carries no accessibility content).
    /// Each node is a button that announces its title and connection count and
    /// opens the note when activated.
    private var accessibilityNodeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(accessibilityNodes) { node in
                    Button {
                        workspace.selectFile(node.url)
                    } label: {
                        Text(node.title)
                    }
                    .accessibilityLabel(node.title)
                    .accessibilityValue(connectionDescription(for: node))
                    .accessibilityHint("Opens this note")
                    .accessibilityAddTraits(snapshot.selectedNodeID == node.id ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    /// Nodes exposed to assistive technology, ordered most-connected first so the
    /// graph's hubs are encountered early during VoiceOver navigation.
    private var accessibilityNodes: [NoteGraphNode] {
        snapshot.nodes.sorted { lhs, rhs in
            if lhs.degree != rhs.degree {
                return lhs.degree > rhs.degree
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func connectionDescription(for node: NoteGraphNode) -> String {
        let count = node.degree
        return count == 1 ? "1 connection" : "\(count) connections"
    }

    private var labeledNodes: [NoteGraphNode] {
        let ids = visibleLabelNodeIDs
        return snapshot.nodes.filter { ids.contains($0.id) }
    }

    private func handleNodeTap(at location: CGPoint, in size: CGSize) {
        guard let node = nearestNode(to: location, in: size) else { return }
        workspace.selectFile(node.url)
    }

    /// Returns the visible node whose drawn circle is nearest the given point.
    ///
    /// The hit radius matches each node's drawn radius (with a small minimum for
    /// tiny nodes), so large hub nodes are tappable out to their visible edge and
    /// clustered nodes resolve to the closest one rather than the first in draw
    /// order. Ties are broken toward larger (higher-degree) nodes.
    private func nearestNode(to location: CGPoint, in size: CGSize) -> NoteGraphNode? {
        let minimumTapRadius: CGFloat = 12
        var best: (node: NoteGraphNode, distanceSquared: CGFloat, degree: Int)?

        for node in snapshot.nodes {
            guard let position = layout.positions[node.id] else { continue }
            let screenPos = transformed(position, in: size)
            let dx = location.x - screenPos.x
            let dy = location.y - screenPos.y
            let distanceSquared = dx * dx + dy * dy

            let hitRadius = max(nodeDiameter(for: node) / 2, minimumTapRadius)
            guard distanceSquared <= hitRadius * hitRadius else { continue }

            if let current = best {
                let isCloser = distanceSquared < current.distanceSquared
                let isTieButLarger = distanceSquared == current.distanceSquared && node.degree > current.degree
                guard isCloser || isTieButLarger else { continue }
            }

            best = (node, distanceSquared, node.degree)
        }

        return best?.node
    }

    private func drawEdges(in context: inout GraphicsContext, size: CGSize) {
        for edge in snapshot.edges {
            guard let source = layout.positions[edge.source],
                  let target = layout.positions[edge.target] else {
                continue
            }

            let sourcePoint = transformed(source, in: size)
            let targetPoint = transformed(target, in: size)
            var path = Path()
            path.move(to: sourcePoint)
            path.addLine(to: targetPoint)
            context.stroke(
                path,
                with: .color(edgeColor(for: edge)),
                style: StrokeStyle(lineWidth: edgeWidth(for: edge), lineCap: .round)
            )
        }
    }

    private func drawNodes(in context: inout GraphicsContext, size: CGSize) {
        for node in snapshot.nodes {
            guard let position = layout.positions[node.id] else { continue }
            let screenPos = transformed(position, in: size)
            let diameter = nodeDiameter(for: node)
            let isSelected = snapshot.selectedNodeID == node.id
            let rect = CGRect(
                x: screenPos.x - diameter / 2,
                y: screenPos.y - diameter / 2,
                width: diameter,
                height: diameter
            )

            if isSelected {
                let shadowRect = rect.insetBy(dx: -6, dy: -6)
                context.fill(
                    Circle().path(in: shadowRect),
                    with: .color(Color.accentColor.opacity(0.18))
                )
            }

            context.fill(Circle().path(in: rect), with: .color(nodeFill(for: node)))
            context.stroke(
                Circle().path(in: rect),
                with: .color(nodeStroke(for: node)),
                style: StrokeStyle(lineWidth: isSelected ? 2.4 : 1)
            )
        }
    }

    private func nodeLabel(_ node: NoteGraphNode, position: CGPoint) -> some View {
        let isSelected = snapshot.selectedNodeID == node.id
        let size = nodeDiameter(for: node)

        return Text(node.title)
            .font(isSelected ? .headline : .caption.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }
            .position(x: position.x, y: position.y + size * 0.86)
            .allowsHitTesting(false)
    }

    private func selectedNodePanel(_ selectedNode: NoteGraphNode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedNode.title)
                        .font(.title3.weight(.semibold))

                    Text(selectedNode.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                statPill(value: snapshot.nodes.count, title: "Notes")
                statPill(value: snapshot.edges.count, title: "Links")
                statPill(value: selectedNode.incomingCount, title: "Backlinks")
                statPill(value: selectedNode.outgoingCount, title: "Out")
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    private var controlsPanel: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 10) {
                graphControlButton(systemImage: "minus.magnifyingglass", help: "Zoom Out") {
                    adjustZoom(to: viewport.zoom * 0.88)
                }

                Text("\(Int(viewport.zoom * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52)

                graphControlButton(systemImage: "plus.magnifyingglass", help: "Zoom In") {
                    adjustZoom(to: viewport.zoom * 1.12)
                }

                Divider()
                    .frame(height: 22)

                graphControlButton(systemImage: "scope", help: "Center Graph") {
                    resetViewport()
                }

                graphControlButton(systemImage: "arrow.clockwise", help: "Relayout Graph") {
                    // Bumping the seed changes `layoutTopologyKey`, which triggers
                    // `scheduleLayout()` via `onChange`.
                    relayoutSeed += 1
                }

                Divider()
                    .frame(height: 22)

                graphControlButton(
                    systemImage: filter.isEmpty
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill",
                    help: filter.isEmpty ? "Filter Graph" : "Active filter — click to edit"
                ) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        isFilterBarPresented.toggle()
                    }
                }

                if isComputingLayout {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }

            if isFilterBarPresented {
                filterPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Filter")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !filter.isEmpty {
                    Button("Clear") { filter = GraphFilter() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Search")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Title or path", text: $filter.titleSearch)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Min connections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(filter.minDegree)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(filter.minDegree) },
                        set: { filter.minDegree = Int($0.rounded()) }
                    ),
                    in: 0...10,
                    step: 1
                )
                .controlSize(.small)
            }

        }
        .padding(14)
        .frame(width: 240, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
    }

    private var relatedNotesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connected Notes")
                .font(.subheadline.weight(.semibold))

            ForEach(Array(connectedNodes.prefix(6))) { node in
                Button {
                    workspace.selectFile(node.url)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(snapshot.connectedNodeIDs.contains(node.id) ? Color.accentColor : Color.secondary.opacity(0.5))
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.title)
                                .lineLimit(1)
                            Text(node.relativePath)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text("\(node.degree)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        }
    }

    private func statPill(value: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func graphControlButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func nodeDiameter(for node: NoteGraphNode) -> CGFloat {
        let clampedDegree = CGFloat(min(max(node.degree, 1), 12))
        let base = snapshot.selectedNodeID == node.id ? 15 : 9
        return CGFloat(base) + clampedDegree * 1.15
    }

    private func nodeFill(for node: NoteGraphNode) -> Color {
        if snapshot.selectedNodeID == node.id {
            return .accentColor
        }

        if hoveredNodeID == node.id {
            return .accentColor.opacity(0.82)
        }

        if snapshot.connectedNodeIDs.contains(node.id) {
            return .accentColor.opacity(0.48)
        }

        return Color.primary.opacity(0.26)
    }

    private func nodeStroke(for node: NoteGraphNode) -> Color {
        if snapshot.selectedNodeID == node.id || hoveredNodeID == node.id {
            return .white.opacity(0.95)
        }

        return Color.white.opacity(0.22)
    }

    private func edgeColor(for edge: NoteGraphEdge) -> Color {
        if edge.source == snapshot.selectedNodeID || edge.target == snapshot.selectedNodeID {
            return .accentColor.opacity(0.5)
        }

        if edge.source == hoveredNodeID || edge.target == hoveredNodeID {
            return .accentColor.opacity(0.34)
        }

        return Color.primary.opacity(0.11)
    }

    private func edgeWidth(for edge: NoteGraphEdge) -> CGFloat {
        if edge.source == snapshot.selectedNodeID || edge.target == snapshot.selectedNodeID {
            return 1.7
        }

        return 1.05
    }

    private func transformed(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let scale = min(size.width, size.height) * 0.34 * viewport.zoom
        return CGPoint(
            x: size.width / 2 + viewport.offset.width + point.x * scale,
            y: size.height / 2 + viewport.offset.height + point.y * scale
        )
    }

    private func adjustZoom(to proposedZoom: CGFloat) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.85)) {
            viewport.zoom = min(max(proposedZoom, minimumZoom), maximumZoom)
        }
        viewport.commitZoom()
    }

    private func scheduleLayout() {
        let snapshot = layoutSnapshot
        let key = layoutTopologyKey
        layoutTask?.cancel()

        guard !snapshot.nodes.isEmpty else {
            layout = .empty
            laidOutTopology = key
            isComputingLayout = false
            return
        }

        // When only the pinned node changed, re-center the existing positions
        // instead of re-running the O(n²) simulation. This keeps node positions
        // stable (no reshuffle) and avoids a CPU spike on rapid selection changes.
        if canRecenterOnly(for: key),
           let recentered = NoteGraphLayoutEngine.recenter(layout, for: snapshot) {
            withAnimation(layoutAnimation) {
                layout = recentered
            }
            laidOutTopology = key
            isComputingLayout = false
            return
        }

        isComputingLayout = true
        let seed = relayoutSeed
        layoutTask = Task {
            let computedLayout = await Task.detached(priority: .userInitiated) {
                NoteGraphLayoutEngine.generate(for: snapshot, relayoutSeed: seed)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(layoutAnimation) {
                    layout = computedLayout
                }
                laidOutTopology = key
                isComputingLayout = false
            }
        }
    }

    /// Spring used when settling a freshly computed layout, or `nil` (instant)
    /// when the user has opted into Reduce Motion.
    private var layoutAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)
    }

    private func resetViewport() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.84)) {
            viewport.reset()
        }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                viewport.offset = CGSize(
                    width: viewport.lastCommittedOffset.width + value.translation.width,
                    height: viewport.lastCommittedOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                viewport.offset = CGSize(
                    width: viewport.lastCommittedOffset.width + value.translation.width,
                    height: viewport.lastCommittedOffset.height + value.translation.height
                )
                viewport.commitOffset()
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                viewport.zoom = min(max(viewport.lastCommittedZoom * value, minimumZoom), maximumZoom)
            }
            .onEnded { value in
                viewport.zoom = min(max(viewport.lastCommittedZoom * value, minimumZoom), maximumZoom)
                viewport.commitZoom()
            }
    }
}

struct GraphFilter: Equatable {
    var minDegree: Int = 0
    var titleSearch: String = ""

    var isEmpty: Bool {
        minDegree == 0 && titleSearch.isEmpty
    }
}

/// Identity of the inputs that require a fresh force layout. Equatable so the
/// view can drive `scheduleLayout` from a single `onChange` and skip relayout
/// when only cosmetic filter state changed.
private struct GraphTopologyKey: Equatable {
    let nodeIDs: [URL]
    let edgeIDs: [String]
    let selectedNodeID: URL?
    let relayoutSeed: Int
}

private struct GraphViewport {
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
    var lastCommittedZoom: CGFloat = 1
    var lastCommittedOffset: CGSize = .zero

    mutating func reset() {
        zoom = 1
        offset = .zero
        lastCommittedZoom = 1
        lastCommittedOffset = .zero
    }

    mutating func commitOffset() {
        lastCommittedOffset = offset
    }

    mutating func commitZoom() {
        lastCommittedZoom = zoom
    }
}
