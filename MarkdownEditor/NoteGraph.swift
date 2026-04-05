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

        let nodes = snapshot.nodes
        let indexedNodes = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let pinnedNodeID = snapshot.selectedNodeID
        let depths = makeDepthMap(for: snapshot, pinnedNodeID: pinnedNodeID)
        var positions = initialPositions(
            for: nodes,
            pinnedNodeID: pinnedNodeID,
            depths: depths,
            relayoutSeed: relayoutSeed
        )
        var temperature: CGFloat = 0.32
        let area: CGFloat = 4
        let optimalDistance = sqrt(area / CGFloat(max(nodes.count, 1)))

        for _ in 0..<140 {
            var displacement = Array(repeating: CGVector(dx: 0, dy: 0), count: nodes.count)

            for firstIndex in nodes.indices {
                for secondIndex in nodes.indices where secondIndex > firstIndex {
                    let deltaX = positions[firstIndex].x - positions[secondIndex].x
                    let deltaY = positions[firstIndex].y - positions[secondIndex].y
                    let distance = max(0.025, hypot(deltaX, deltaY))
                    let force = (optimalDistance * optimalDistance) / distance
                    let directionX = deltaX / distance
                    let directionY = deltaY / distance
                    let vector = CGVector(dx: directionX * force, dy: directionY * force)
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
                let distance = max(0.025, hypot(deltaX, deltaY))
                let force = (distance * distance) / max(optimalDistance, 0.01)
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
                    continue
                }

                displacement[index].dx -= positions[index].x * 0.15
                displacement[index].dy -= positions[index].y * 0.15

                let distance = max(0.001, hypot(displacement[index].dx, displacement[index].dy))
                let limitedDistance = min(temperature, distance)
                positions[index].x += (displacement[index].dx / distance) * limitedDistance
                positions[index].y += (displacement[index].dy / distance) * limitedDistance
                positions[index].x = min(max(positions[index].x, -1.4), 1.4)
                positions[index].y = min(max(positions[index].y, -1.4), 1.4)
            }

            temperature *= 0.965
        }

        let normalizedPositions = normalized(positions, pinnedNodeID: pinnedNodeID, nodes: nodes)
        let mappedPositions = Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), normalizedPositions))
        return NoteGraphLayout(positions: mappedPositions)
    }

    private static func makeDepthMap(
        for snapshot: NoteGraphSnapshot,
        pinnedNodeID: URL?
    ) -> [URL: Int] {
        guard let pinnedNodeID else { return [:] }

        var adjacency: [URL: Set<URL>] = [:]
        for edge in snapshot.edges {
            adjacency[edge.source, default: []].insert(edge.target)
            adjacency[edge.target, default: []].insert(edge.source)
        }

        var depths: [URL: Int] = [pinnedNodeID: 0]
        var queue: [URL] = [pinnedNodeID]

        while !queue.isEmpty {
            let nodeID = queue.removeFirst()
            let nextDepth = depths[nodeID, default: 0] + 1

            for neighbor in adjacency[nodeID, default: []] where depths[neighbor] == nil {
                depths[neighbor] = nextDepth
                queue.append(neighbor)
            }
        }

        return depths
    }

    private static func initialPositions(
        for nodes: [NoteGraphNode],
        pinnedNodeID: URL?,
        depths: [URL: Int],
        relayoutSeed: Int
    ) -> [CGPoint] {
        let goldenAngle = CGFloat.pi * (3 - sqrt(5))
        let maximumDepth = max(depths.values.max() ?? 0, 1)

        return nodes.enumerated().map { index, node in
            if node.id == pinnedNodeID {
                return .zero
            }

            let jitter = jitterValue(for: node.id, seed: relayoutSeed)
            let angle = CGFloat(index) * goldenAngle + jitter * 1.7
            let normalizedDepth = CGFloat(depths[node.id, default: maximumDepth + 1]) / CGFloat(maximumDepth + 1)
            let ring = max(0.28, min(1.1, 0.24 + normalizedDepth * 0.78))
            return CGPoint(
                x: cos(angle) * ring,
                y: sin(angle) * ring
            )
        }
    }

    private static func normalized(
        _ positions: [CGPoint],
        pinnedNodeID: URL?,
        nodes: [NoteGraphNode]
    ) -> [CGPoint] {
        let sourcePositions = positions
        let xValues = sourcePositions.map(\.x)
        let yValues = sourcePositions.map(\.y)
        let minX = xValues.min() ?? -1
        let maxX = xValues.max() ?? 1
        let minY = yValues.min() ?? -1
        let maxY = yValues.max() ?? 1
        let width = max(maxX - minX, 0.01)
        let height = max(maxY - minY, 0.01)
        let scale = 1.8 / max(width, height)
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)

        return sourcePositions.enumerated().map { index, point in
            if nodes[index].id == pinnedNodeID {
                return .zero
            }

            return CGPoint(
                x: (point.x - center.x) * scale,
                y: (point.y - center.y) * scale
            )
        }
    }

    private static func jitterValue(for url: URL, seed: Int) -> CGFloat {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in (url.path + "#\(seed)").utf8 {
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
