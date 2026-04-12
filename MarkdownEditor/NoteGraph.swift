import CoreGraphics
import Foundation

struct NoteLinkReference: Hashable, Sendable {
    let destination: String
}

struct NoteGraphNode: Identifiable, Hashable, Sendable {
    let id: URL
    let url: URL
    let title: String
    let relativePath: String
    let incomingCount: Int
    let outgoingCount: Int

    var degree: Int {
        incomingCount + outgoingCount
    }
}

struct NoteGraphEdge: Identifiable, Hashable, Sendable {
    let source: URL
    let target: URL

    var id: String {
        source.path + "->" + target.path
    }
}

struct NoteGraphSnapshot: Sendable, Equatable {
    let nodes: [NoteGraphNode]
    let edges: [NoteGraphEdge]
    let selectedNodeID: URL?
    let connectedNodeIDs: Set<URL>

    static let empty = NoteGraphSnapshot(
        nodes: [],
        edges: [],
        selectedNodeID: nil,
        connectedNodeIDs: []
    )

    var selectedNode: NoteGraphNode? {
        guard let selectedNodeID else { return nil }
        return nodes.first(where: { $0.id == selectedNodeID })
    }

    func backlinks(to targetID: URL?) -> [NoteGraphNode] {
        guard let targetID else { return [] }

        let sourceIDs = Set(edges.compactMap { edge -> URL? in
            edge.target == targetID ? edge.source : nil
        })

        return nodes
            .filter { sourceIDs.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func neighbors(of nodeID: URL?) -> [NoteGraphNode] {
        guard let nodeID else { return [] }

        let relatedIDs = edges.reduce(into: Set<URL>()) { result, edge in
            if edge.source == nodeID {
                result.insert(edge.target)
            } else if edge.target == nodeID {
                result.insert(edge.source)
            }
        }

        let sortedNodes = nodes.sorted { lhs, rhs in
            if lhs.degree != rhs.degree {
                return lhs.degree > rhs.degree
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        return sortedNodes.filter { relatedIDs.contains($0.id) }
    }
}

struct NoteGraphLayout: Sendable, Equatable {
    let positions: [URL: CGPoint]

    static let empty = NoteGraphLayout(positions: [:])
}

enum MarkdownNoteLinkExtractor {
    struct ObsidianNoteLinkMatch {
        let destination: String
        let displayName: String
        let nextIndex: Int
    }

    struct MarkdownLinkMatch {
        let destination: String
        let nextIndex: Int
    }

    private struct FenceDescriptor {
        let character: Character
        let count: Int
    }

    static func references(in markdown: String) -> [NoteLinkReference] {
        let sanitized = sanitizedMarkdown(markdown)
        let characters = Array(sanitized)
        var references: [NoteLinkReference] = []
        var index = 0

        while index < characters.count {
            if let match = obsidianNoteLink(in: characters, from: index) {
                references.append(NoteLinkReference(destination: match.destination))
                index = match.nextIndex
                continue
            }

            if let match = markdownLink(in: characters, from: index) {
                references.append(NoteLinkReference(destination: match.destination))
                index = match.nextIndex
                continue
            }

            index += 1
        }

        return references
    }

    static func obsidianNoteLink(
        in characters: [Character],
        from index: Int
    ) -> ObsidianNoteLinkMatch? {
        guard index + 3 < characters.count else { return nil }
        guard characters[index] == "[",
              characters[index + 1] == "[",
              (index == 0 || characters[index - 1] != "!") else {
            return nil
        }

        var cursor = index + 2
        while cursor + 1 < characters.count {
            if characters[cursor] == "]", characters[cursor + 1] == "]" {
                let rawReference = String(characters[(index + 2)..<cursor])
                let descriptor = parseObsidianNoteReference(rawReference)
                guard !descriptor.destination.isEmpty else {
                    return nil
                }

                return ObsidianNoteLinkMatch(
                    destination: descriptor.destination,
                    displayName: descriptor.displayName,
                    nextIndex: cursor + 2
                )
            }

            if characters[cursor].isNewline {
                return nil
            }

            cursor += 1
        }

        return nil
    }

    static func markdownLink(
        in characters: [Character],
        from index: Int
    ) -> MarkdownLinkMatch? {
        guard index < characters.count,
              characters[index] == "[",
              (index == 0 || characters[index - 1] != "!") else {
            return nil
        }

        var cursor = index + 1
        while cursor < characters.count, characters[cursor] != "]" {
            if characters[cursor].isNewline {
                return nil
            }
            cursor += 1
        }

        guard cursor < characters.count,
              cursor > index + 1,
              cursor + 1 < characters.count,
              characters[cursor + 1] == "(" else {
            return nil
        }

        cursor += 2
        cursor = skipWhitespace(in: characters, from: cursor)

        let destination: String
        if cursor < characters.count, characters[cursor] == "<" {
            cursor += 1
            let start = cursor
            while cursor < characters.count, characters[cursor] != ">" {
                if characters[cursor].isNewline {
                    return nil
                }
                cursor += 1
            }

            guard cursor < characters.count else { return nil }
            destination = String(characters[start..<cursor])
            cursor += 1
        } else {
            let start = cursor
            while cursor < characters.count,
                  characters[cursor] != ")",
                  !characters[cursor].isWhitespace {
                if characters[cursor].isNewline {
                    return nil
                }
                cursor += 1
            }

            destination = String(characters[start..<cursor])
        }

        guard !destination.isEmpty else { return nil }

        cursor = skipWhitespace(in: characters, from: cursor)
        if cursor < characters.count, characters[cursor] != ")" {
            let quote = characters[cursor]
            guard quote == "\"" || quote == "'" else { return nil }

            cursor += 1
            while cursor < characters.count, characters[cursor] != quote {
                if characters[cursor].isNewline {
                    return nil
                }
                cursor += 1
            }

            guard cursor < characters.count else { return nil }
            cursor += 1
            cursor = skipWhitespace(in: characters, from: cursor)
        }

        guard cursor < characters.count, characters[cursor] == ")" else {
            return nil
        }

        return MarkdownLinkMatch(destination: destination, nextIndex: cursor + 1)
    }

    static func parseObsidianNoteReference(_ rawReference: String) -> (destination: String, displayName: String) {
        let trimmed = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: "|", maxSplits: 1).map(String.init)
        let destinationWithFragment = pieces.first ?? trimmed
        let destination = destinationWithFragment
            .split(separator: "#", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let alias = pieces.count > 1
            ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let fallback = ((destination as NSString).deletingPathExtension as NSString).lastPathComponent
        let displayName = alias?.isEmpty == false ? alias! : (fallback.isEmpty ? destination : fallback)

        return (destination, displayName)
    }

    private static func sanitizedMarkdown(_ markdown: String) -> String {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var sanitizedLines: [String] = []
        var activeFence: FenceDescriptor?

        for line in lines {
            let lineString = String(line)
            let trimmed = lineString.trimmingLeadingWhitespace()

            if let fence = fenceDescriptor(in: trimmed) {
                if let currentFence = activeFence {
                    if currentFence.character == fence.character, fence.count >= currentFence.count {
                        activeFence = nil
                    }
                } else {
                    activeFence = fence
                }

                sanitizedLines.append(String(repeating: " ", count: lineString.count))
                continue
            }

            if activeFence != nil {
                sanitizedLines.append(String(repeating: " ", count: lineString.count))
                continue
            }

            sanitizedLines.append(maskInlineCode(in: lineString))
        }

        return sanitizedLines.joined(separator: "\n")
    }

    private static func maskInlineCode(in line: String) -> String {
        let characters = Array(line)
        var result = ""
        var index = 0
        var activeFenceLength: Int?

        while index < characters.count {
            if characters[index] == "`" {
                let runStart = index
                while index < characters.count, characters[index] == "`" {
                    index += 1
                }

                let fenceLength = index - runStart
                result += String(repeating: " ", count: fenceLength)

                if activeFenceLength == fenceLength {
                    activeFenceLength = nil
                } else if activeFenceLength == nil {
                    activeFenceLength = fenceLength
                }

                continue
            }

            if activeFenceLength == nil {
                result.append(characters[index])
            } else {
                result.append(" ")
            }

            index += 1
        }

        return result
    }

    private static func fenceDescriptor(in trimmedLine: String) -> FenceDescriptor? {
        guard let first = trimmedLine.first, first == "`" || first == "~" else {
            return nil
        }

        let count = trimmedLine.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        return FenceDescriptor(character: first, count: count)
    }

    private static func skipWhitespace(in characters: [Character], from startIndex: Int) -> Int {
        var cursor = startIndex
        while cursor < characters.count, characters[cursor].isWhitespace {
            cursor += 1
        }
        return cursor
    }
}

struct NoteReferenceResolver: Sendable {
    private let vaultURL: URL?
    private let noteURLs: Set<URL>
    private let relativePathLookup: [String: URL]
    private let relativeStemLookup: [String: URL]
    private let basenameLookup: [String: URL]
    private let stemLookup: [String: URL]

    init(noteURLs: [URL], vaultURL: URL?) {
        let standardizedVaultURL = vaultURL?.resolvingSymlinksInPath().standardizedFileURL
        let standardizedNoteURLs = noteURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL }

        self.vaultURL = standardizedVaultURL
        self.noteURLs = Set(standardizedNoteURLs)

        var relativePathLookup: [String: URL] = [:]
        var relativeStemLookup: [String: URL] = [:]
        var basenameEntries: [(String, URL)] = []
        var stemEntries: [(String, URL)] = []

        for noteURL in standardizedNoteURLs {
            let fileName = noteURL.lastPathComponent
            basenameEntries.append((Self.normalizeLookupKey(fileName), noteURL))
            stemEntries.append((Self.normalizeLookupKey(noteURL.deletingPathExtension().lastPathComponent), noteURL))

            if let standardizedVaultURL,
               let relativePath = Self.relativePath(from: standardizedVaultURL, to: noteURL) {
                let normalizedRelativePath = Self.normalizeLookupKey(relativePath)
                relativePathLookup[normalizedRelativePath] = noteURL

                let relativeStem = (relativePath as NSString).deletingPathExtension
                relativeStemLookup[Self.normalizeLookupKey(relativeStem)] = noteURL
            }
        }

        self.relativePathLookup = relativePathLookup
        self.relativeStemLookup = relativeStemLookup
        self.basenameLookup = Self.uniqueLookup(from: basenameEntries)
        self.stemLookup = Self.uniqueLookup(from: stemEntries)
    }

    func resolve(destination rawDestination: String, from sourceURL: URL?) -> URL? {
        let normalizedDestination = Self.normalizedDestination(rawDestination)
        guard !normalizedDestination.isEmpty else {
            return nil
        }

        if let directURL = Self.explicitFileURL(from: normalizedDestination) {
            return noteURLs.contains(directURL) ? directURL : nil
        }

        if let sourceURL,
           let relativeMatch = resolveRelativeDestination(normalizedDestination, from: sourceURL) {
            return relativeMatch
        }

        let normalizedLookupKey = Self.normalizeLookupKey(normalizedDestination)
        if let match = relativePathLookup[normalizedLookupKey] {
            return match
        }

        if let match = relativeStemLookup[Self.normalizeLookupKey(Self.removingKnownExtension(from: normalizedDestination))] {
            return match
        }

        let fileName = (normalizedDestination as NSString).lastPathComponent
        if let match = basenameLookup[Self.normalizeLookupKey(fileName)] {
            return match
        }

        let stem = (fileName as NSString).deletingPathExtension
        if let match = stemLookup[Self.normalizeLookupKey(stem)] {
            return match
        }

        if normalizedDestination.hasPrefix("/"),
           let vaultRelativeMatch = relativePathLookup[Self.normalizeLookupKey(String(normalizedDestination.dropFirst()))] {
            return vaultRelativeMatch
        }

        return nil
    }

    private func resolveRelativeDestination(_ destination: String, from sourceURL: URL) -> URL? {
        let sourceDirectoryURL = sourceURL.deletingLastPathComponent()

        for candidate in Self.relativeCandidates(for: destination, relativeTo: sourceDirectoryURL) {
            if noteURLs.contains(candidate) {
                return candidate
            }
        }

        if let standardizedVaultURL = vaultURL {
            for candidate in Self.relativeCandidates(for: destination, relativeTo: standardizedVaultURL) {
                if noteURLs.contains(candidate) {
                    return candidate
                }
            }
        }

        return nil
    }

    private static func uniqueLookup(from entries: [(String, URL)]) -> [String: URL] {
        var grouped: [String: [URL]] = [:]
        for (key, url) in entries where !key.isEmpty {
            grouped[key, default: []].append(url)
        }

        return grouped.reduce(into: [:]) { result, entry in
            guard entry.value.count == 1, let url = entry.value.first else {
                return
            }
            result[entry.key] = url
        }
    }

    private static func relativeCandidates(for destination: String, relativeTo baseURL: URL) -> [URL] {
        let destinationPathExtension = (destination as NSString).pathExtension.lowercased()
        let candidates: [String]

        if markdownNoteExtensions.contains(destinationPathExtension) {
            candidates = [destination]
        } else if destinationPathExtension.isEmpty {
            candidates = markdownNoteExtensionsInPriorityOrder.map { destination + "." + $0 }
        } else {
            candidates = []
        }

        return candidates.map { candidate in
            URL(fileURLWithPath: candidate, relativeTo: baseURL)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
    }

    private static func normalizedDestination(_ destination: String) -> String {
        var trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }

        let withoutFragment = trimmed.split(separator: "#", maxSplits: 1).first.map(String.init) ?? trimmed
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        return decoded.replacingOccurrences(of: "\\", with: "/")
    }

    private static func normalizeLookupKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
    }

    private static func removingKnownExtension(from destination: String) -> String {
        let pathExtension = (destination as NSString).pathExtension.lowercased()
        guard markdownNoteExtensions.contains(pathExtension) else {
            return destination
        }

        return (destination as NSString).deletingPathExtension
    }

    private static func explicitFileURL(from destination: String) -> URL? {
        if let url = URL(string: destination), url.scheme?.lowercased() == "file" {
            return url.resolvingSymlinksInPath().standardizedFileURL
        }

        guard destination.hasPrefix("/") else {
            return nil
        }

        return URL(fileURLWithPath: destination)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func relativePath(from baseURL: URL, to fileURL: URL) -> String? {
        let standardizedBaseURL = baseURL.standardizedFileURL
        let standardizedFileURL = fileURL.standardizedFileURL
        let basePath = standardizedBaseURL.path.hasSuffix("/") ? standardizedBaseURL.path : standardizedBaseURL.path + "/"
        guard standardizedFileURL.path.hasPrefix(basePath) else {
            return nil
        }

        return String(standardizedFileURL.path.dropFirst(basePath.count))
    }
}

enum NoteGraphBuilder {
    private struct NoteEntry {
        let url: URL
        let title: String
        let relativePath: String
        let links: [NoteLinkReference]
    }

    static func makeSnapshot(
        files: [FileItem],
        metadataByPath: [String: CachedMarkdownMetadata],
        vaultURL: URL?,
        selectedFileURL: URL?,
        liveSelectedMarkdown: String?
    ) -> NoteGraphSnapshot {
        let standardizedSelectedFileURL = selectedFileURL?.resolvingSymlinksInPath().standardizedFileURL
        let standardizedVaultURL = vaultURL?.resolvingSymlinksInPath().standardizedFileURL

        let entries = files.map { file -> NoteEntry in
            let standardizedURL = file.url.resolvingSymlinksInPath().standardizedFileURL
            let metadataKey = standardizedURL.path
            let cachedMetadata = metadataByPath[metadataKey]
            let isSelected = standardizedSelectedFileURL == standardizedURL

            let title: String
            let links: [NoteLinkReference]

            if isSelected, let liveSelectedMarkdown {
                title = Workspace.extractTitle(from: liveSelectedMarkdown) ?? file.sidebarTitle
                links = MarkdownNoteLinkExtractor.references(in: liveSelectedMarkdown)
            } else {
                title = cachedMetadata?.noteTitle ?? file.sidebarTitle
                links = cachedMetadata?.noteLinks ?? []
            }

            let relativePath = relativePath(for: standardizedURL, relativeTo: standardizedVaultURL) ?? file.name
            return NoteEntry(
                url: standardizedURL,
                title: title,
                relativePath: relativePath,
                links: links
            )
        }

        let resolver = NoteReferenceResolver(
            noteURLs: entries.map(\.url),
            vaultURL: standardizedVaultURL
        )

        var outgoingBySource: [URL: Set<URL>] = [:]
        var incomingCounts: [URL: Int] = [:]
        var uniqueEdges: Set<NoteGraphEdge> = []

        for entry in entries {
            for reference in entry.links {
                guard let resolvedURL = resolver.resolve(destination: reference.destination, from: entry.url),
                      resolvedURL != entry.url else {
                    continue
                }

                let edge = NoteGraphEdge(source: entry.url, target: resolvedURL)
                guard uniqueEdges.insert(edge).inserted else { continue }

                outgoingBySource[entry.url, default: []].insert(resolvedURL)
                incomingCounts[resolvedURL, default: 0] += 1
            }
        }

        let nodes = entries.map { entry in
            NoteGraphNode(
                id: entry.url,
                url: entry.url,
                title: entry.title,
                relativePath: entry.relativePath,
                incomingCount: incomingCounts[entry.url, default: 0],
                outgoingCount: outgoingBySource[entry.url]?.count ?? 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.title != rhs.title {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }

        let edges = uniqueEdges.sorted { lhs, rhs in
            if lhs.source != rhs.source {
                return lhs.source.path.localizedStandardCompare(rhs.source.path) == .orderedAscending
            }
            return lhs.target.path.localizedStandardCompare(rhs.target.path) == .orderedAscending
        }

        let connectedNodeIDs = edges.reduce(into: Set<URL>()) { result, edge in
            guard let standardizedSelectedFileURL else { return }

            if edge.source == standardizedSelectedFileURL {
                result.insert(edge.target)
            } else if edge.target == standardizedSelectedFileURL {
                result.insert(edge.source)
            }
        }

        let selectedNodeID = nodes.contains(where: { $0.id == standardizedSelectedFileURL })
            ? standardizedSelectedFileURL
            : nil

        return NoteGraphSnapshot(
            nodes: nodes,
            edges: edges,
            selectedNodeID: selectedNodeID,
            connectedNodeIDs: connectedNodeIDs
        )
    }

    private static func relativePath(for url: URL, relativeTo vaultURL: URL?) -> String? {
        guard let vaultURL else { return nil }
        let basePath = vaultURL.path.hasSuffix("/") ? vaultURL.path : vaultURL.path + "/"
        guard url.path.hasPrefix(basePath) else { return nil }
        return String(url.path.dropFirst(basePath.count))
    }
}

enum NoteGraphLayoutEngine {
    static func generate(for snapshot: NoteGraphSnapshot, relayoutSeed: Int) -> NoteGraphLayout {
        guard !snapshot.nodes.isEmpty else {
            return .empty
        }

        if snapshot.nodes.count == 1, let node = snapshot.nodes.first {
            return NoteGraphLayout(positions: [node.id: .zero])
        }

        if snapshot.edges.isEmpty {
            return scatterLayout(
                for: snapshot.nodes,
                pinnedNodeID: snapshot.selectedNodeID,
                relayoutSeed: relayoutSeed
            )
        }

        let nodes = snapshot.nodes
        let indexedNodes = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let pinnedNodeID = snapshot.selectedNodeID
        let components = connectedComponents(for: snapshot)
        let componentByNode = Dictionary(uniqueKeysWithValues: components.enumerated().flatMap { componentIndex, component in
            component.map { ($0, componentIndex) }
        })
        let componentAnchors = makeComponentAnchors(
            for: components,
            pinnedNodeID: pinnedNodeID,
            relayoutSeed: relayoutSeed
        )
        var positions = initialPositions(
            for: nodes,
            pinnedNodeID: pinnedNodeID,
            componentByNode: componentByNode,
            componentAnchors: componentAnchors,
            components: components,
            relayoutSeed: relayoutSeed
        )
        var velocities = Array(repeating: CGVector.zero, count: nodes.count)
        var temperature: CGFloat = 0.11
        let idealEdgeLength = max(0.34, 1.22 / sqrt(CGFloat(max(nodes.count, 1))))
        let maxRadius: CGFloat = 2.4
        let selectedComponentIndex = pinnedNodeID.flatMap { componentByNode[$0] }

        for _ in 0..<220 {
            var displacement = Array(repeating: CGVector.zero, count: nodes.count)

            for firstIndex in nodes.indices {
                for secondIndex in nodes.indices where secondIndex > firstIndex {
                    let deltaX = positions[firstIndex].x - positions[secondIndex].x
                    let deltaY = positions[firstIndex].y - positions[secondIndex].y
                    let distance = max(0.045, hypot(deltaX, deltaY))
                    let sameComponent = componentByNode[nodes[firstIndex].id] == componentByNode[nodes[secondIndex].id]
                    let repulsion = sameComponent ? 0.016 / (distance * distance) : 0.009 / (distance * distance)
                    let directionX = deltaX / distance
                    let directionY = deltaY / distance
                    let vector = CGVector(dx: directionX * repulsion, dy: directionY * repulsion)
                    displacement[firstIndex].dx += vector.dx
                    displacement[firstIndex].dy += vector.dy
                    displacement[secondIndex].dx -= vector.dx
                    displacement[secondIndex].dy -= vector.dy
                }
            }

            for edge in snapshot.edges {
                guard let sourceIndex = indexedNodes[edge.source],
                      let targetIndex = indexedNodes[edge.target] else {
                    continue
                }

                let deltaX = positions[sourceIndex].x - positions[targetIndex].x
                let deltaY = positions[sourceIndex].y - positions[targetIndex].y
                let distance = max(0.045, hypot(deltaX, deltaY))
                let force = (distance - idealEdgeLength) * 0.11
                let directionX = deltaX / distance
                let directionY = deltaY / distance
                let vector = CGVector(dx: directionX * force, dy: directionY * force)

                displacement[sourceIndex].dx -= vector.dx
                displacement[sourceIndex].dy -= vector.dy
                displacement[targetIndex].dx += vector.dx
                displacement[targetIndex].dy += vector.dy
            }

            for index in nodes.indices {
                let node = nodes[index]

                if node.id == pinnedNodeID {
                    positions[index] = .zero
                    velocities[index] = .zero
                    continue
                }

                let componentIndex = componentByNode[node.id] ?? 0
                let componentAnchor = componentAnchors[componentIndex] ?? .zero
                let anchorStrength: CGFloat = componentIndex == selectedComponentIndex ? 0.055 : 0.04
                displacement[index].dx += (componentAnchor.x - positions[index].x) * anchorStrength
                displacement[index].dy += (componentAnchor.y - positions[index].y) * anchorStrength

                // Keep isolated or weakly-connected components inside a circular field without boxing them in.
                displacement[index].dx += -positions[index].x * 0.012
                displacement[index].dy += -positions[index].y * 0.012

                velocities[index].dx = (velocities[index].dx + displacement[index].dx) * 0.84
                velocities[index].dy = (velocities[index].dy + displacement[index].dy) * 0.84

                let velocityMagnitude = max(0.001, hypot(velocities[index].dx, velocities[index].dy))
                let limitedDistance = min(temperature, velocityMagnitude)
                positions[index].x += (velocities[index].dx / velocityMagnitude) * limitedDistance
                positions[index].y += (velocities[index].dy / velocityMagnitude) * limitedDistance

                let radius = hypot(positions[index].x, positions[index].y)
                if radius > maxRadius {
                    let scale = maxRadius / radius
                    positions[index].x *= scale
                    positions[index].y *= scale
                }
            }

            temperature *= 0.989
        }

        let normalizedPositions = normalized(positions, pinnedNodeID: pinnedNodeID, nodes: nodes)
        let mappedPositions = Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), normalizedPositions))
        return NoteGraphLayout(positions: mappedPositions)
    }

    private static func connectedComponents(
        for snapshot: NoteGraphSnapshot
    ) -> [[URL]] {
        let nodeIDs = snapshot.nodes.map(\.id)
        var adjacency: [URL: Set<URL>] = Dictionary(uniqueKeysWithValues: nodeIDs.map { ($0, []) })

        for edge in snapshot.edges {
            adjacency[edge.source, default: []].insert(edge.target)
            adjacency[edge.target, default: []].insert(edge.source)
        }

        var remaining = Set(nodeIDs)
        var components: [[URL]] = []

        while let start = remaining.first {
            var stack = [start]
            var component: [URL] = []
            remaining.remove(start)

            while let nodeID = stack.popLast() {
                component.append(nodeID)

                for neighbor in adjacency[nodeID, default: []] where remaining.contains(neighbor) {
                    remaining.remove(neighbor)
                    stack.append(neighbor)
                }
            }

            components.append(component)
        }

        return components.sorted { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.first?.path.localizedStandardCompare(rhs.first?.path ?? "") == .orderedAscending
        }
    }

    private static func makeComponentAnchors(
        for components: [[URL]],
        pinnedNodeID: URL?,
        relayoutSeed: Int
    ) -> [Int: CGPoint] {
        let selectedComponentIndex = pinnedNodeID.flatMap { pinnedNodeID in
            components.firstIndex(where: { $0.contains(pinnedNodeID) })
        }

        var anchors: [Int: CGPoint] = [:]
        if let selectedComponentIndex {
            anchors[selectedComponentIndex] = .zero
        }

        let otherComponentIndices = components.indices.filter { $0 != selectedComponentIndex }
        let goldenAngle = CGFloat.pi * (3 - sqrt(5))

        for (offset, componentIndex) in otherComponentIndices.enumerated() {
            let baseAngle = CGFloat(offset + 1) * goldenAngle
            let jitter = (random01(for: "component-\(componentIndex)", seed: relayoutSeed, salt: 1) - 0.5) * 0.75
            let angle = baseAngle + jitter
            let radius = 0.95 + CGFloat(offset / 6) * 0.55 + sqrt(CGFloat(max(components[componentIndex].count, 1))) * 0.09
            anchors[componentIndex] = CGPoint(
                x: cos(angle) * radius,
                y: sin(angle) * radius
            )
        }

        if anchors.isEmpty {
            anchors[0] = .zero
        }

        return anchors
    }

    private static func scatterLayout(
        for nodes: [NoteGraphNode],
        pinnedNodeID: URL?,
        relayoutSeed: Int
    ) -> NoteGraphLayout {
        var positions = nodes.map { node in
            if node.id == pinnedNodeID {
                return CGPoint.zero
            }

            let angle = random01(for: node.id.path, seed: relayoutSeed, salt: 1) * (.pi * 2)
            let radius = 0.32 + sqrt(random01(for: node.id.path, seed: relayoutSeed, salt: 2)) * 1.65
            return CGPoint(
                x: cos(angle) * radius,
                y: sin(angle) * radius
            )
        }
        var velocities = Array(repeating: CGVector.zero, count: nodes.count)
        var temperature: CGFloat = 0.075
        let maxRadius: CGFloat = 2.1

        for _ in 0..<140 {
            var displacement = Array(repeating: CGVector.zero, count: nodes.count)

            for firstIndex in nodes.indices {
                for secondIndex in nodes.indices where secondIndex > firstIndex {
                    let deltaX = positions[firstIndex].x - positions[secondIndex].x
                    let deltaY = positions[firstIndex].y - positions[secondIndex].y
                    let distance = max(0.05, hypot(deltaX, deltaY))
                    let repulsion = 0.02 / (distance * distance)
                    let directionX = deltaX / distance
                    let directionY = deltaY / distance
                    let vector = CGVector(dx: directionX * repulsion, dy: directionY * repulsion)
                    displacement[firstIndex].dx += vector.dx
                    displacement[firstIndex].dy += vector.dy
                    displacement[secondIndex].dx -= vector.dx
                    displacement[secondIndex].dy -= vector.dy
                }
            }

            for index in nodes.indices {
                if nodes[index].id == pinnedNodeID {
                    positions[index] = .zero
                    velocities[index] = .zero
                    continue
                }

                displacement[index].dx += -positions[index].x * 0.016
                displacement[index].dy += -positions[index].y * 0.016

                velocities[index].dx = (velocities[index].dx + displacement[index].dx) * 0.82
                velocities[index].dy = (velocities[index].dy + displacement[index].dy) * 0.82

                let velocityMagnitude = max(0.001, hypot(velocities[index].dx, velocities[index].dy))
                let limitedDistance = min(temperature, velocityMagnitude)
                positions[index].x += (velocities[index].dx / velocityMagnitude) * limitedDistance
                positions[index].y += (velocities[index].dy / velocityMagnitude) * limitedDistance

                let radius = hypot(positions[index].x, positions[index].y)
                if radius > maxRadius {
                    let scale = maxRadius / radius
                    positions[index].x *= scale
                    positions[index].y *= scale
                }
            }

            temperature *= 0.988
        }

        let normalizedPositions = normalized(
            positions,
            pinnedNodeID: pinnedNodeID,
            nodes: nodes
        )
        return NoteGraphLayout(
            positions: Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), normalizedPositions))
        )
    }

    private static func initialPositions(
        for nodes: [NoteGraphNode],
        pinnedNodeID: URL?,
        componentByNode: [URL: Int],
        componentAnchors: [Int: CGPoint],
        components: [[URL]],
        relayoutSeed: Int
    ) -> [CGPoint] {
        nodes.map { node in
            if node.id == pinnedNodeID {
                return .zero
            }

            let componentIndex = componentByNode[node.id] ?? 0
            let componentAnchor = componentAnchors[componentIndex] ?? .zero
            let clusterRadius = 0.18 + sqrt(CGFloat(max(components[componentIndex].count, 1))) * 0.055
            let angle = random01(for: node.id.path, seed: relayoutSeed, salt: 3) * (.pi * 2)
            let radius = sqrt(random01(for: node.id.path, seed: relayoutSeed, salt: 4)) * clusterRadius
            return CGPoint(
                x: componentAnchor.x + cos(angle) * radius,
                y: componentAnchor.y + sin(angle) * radius
            )
        }
    }

    private static func normalized(
        _ positions: [CGPoint],
        pinnedNodeID: URL?,
        nodes: [NoteGraphNode]
    ) -> [CGPoint] {
        if let pinnedNodeID {
            let adjusted = positions.enumerated().map { index, point in
                nodes[index].id == pinnedNodeID ? CGPoint.zero : point
            }
            let maxRadius = adjusted
                .enumerated()
                .filter { nodes[$0.offset].id != pinnedNodeID }
                .map { hypot($0.element.x, $0.element.y) }
                .max() ?? 1
            let scale = 1.68 / max(maxRadius, 0.01)

            return adjusted.enumerated().map { index, point in
                nodes[index].id == pinnedNodeID
                    ? .zero
                    : CGPoint(x: point.x * scale, y: point.y * scale)
            }
        }

        let centroid = CGPoint(
            x: positions.map(\.x).reduce(0, +) / CGFloat(max(positions.count, 1)),
            y: positions.map(\.y).reduce(0, +) / CGFloat(max(positions.count, 1))
        )
        let recentered = positions.map {
            CGPoint(x: $0.x - centroid.x, y: $0.y - centroid.y)
        }
        let maxRadius = recentered.map { hypot($0.x, $0.y) }.max() ?? 1
        let scale = 1.68 / max(maxRadius, 0.01)

        return recentered.map { point in
            CGPoint(x: point.x * scale, y: point.y * scale)
        }
    }

    private static func random01(for key: String, seed: Int, salt: Int) -> CGFloat {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(key)#\(seed)#\(salt)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        let normalized = Double(hash % 10_000) / 10_000
        return CGFloat(normalized)
    }
}

private let markdownNoteExtensionsInPriorityOrder = ["md", "markdown", "mdown"]
private let markdownNoteExtensions: Set<String> = Set(markdownNoteExtensionsInPriorityOrder)

private extension String {
    func trimmingLeadingWhitespace() -> String {
        let trimmedScalars = unicodeScalars.drop(while: { CharacterSet.whitespaces.contains($0) })
        return String(String.UnicodeScalarView(trimmedScalars))
    }
}
