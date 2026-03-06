import Foundation

// MARK: - Diagram Models

enum MermaidDiagram {
    case flowchart(FlowchartGraph)
    case sequence(SequenceDiagram)
    case pie(PieChart)
    case classDiagram(ClassDiagramGraph)
}

// MARK: Flowchart

enum FlowDirection { case TD, LR, BT, RL }
enum NodeShape { case rect, rounded, diamond, circle, stadium }
enum EdgeStyle { case solid, dotted, thick, plain }

struct FlowNode: Identifiable {
    let id: String
    var label: String
    var shape: NodeShape = .rect
}

struct FlowEdge {
    let from: String
    let to: String
    var label: String = ""
    var style: EdgeStyle = .solid
}

struct FlowchartGraph {
    var direction: FlowDirection = .TD
    var nodes: [String: FlowNode] = [:]
    var edges: [FlowEdge] = []
    var nodeOrder: [String] = []
}

// MARK: Sequence

enum ArrowType { case solid, dashed, cross }

struct SeqMessage {
    let from: String
    let to: String
    let text: String
    let arrowType: ArrowType
}

struct SequenceDiagram {
    var participants: [String] = []
    var participantLabels: [String: String] = [:]
    var messages: [SeqMessage] = []
}

// MARK: Pie

struct PieSlice {
    let label: String
    let value: Double
}

struct PieChart {
    var title: String = ""
    var slices: [PieSlice] = []
}

// MARK: Class Diagram

struct ClassMember {
    let name: String
    let isMethod: Bool
}

struct ClassBox: Identifiable {
    let id: String
    let name: String
    var members: [ClassMember] = []
}

enum RelationType { case inheritance, composition, aggregation, association }

struct ClassRelation {
    let from: String
    let to: String
    let type: RelationType
    var label: String = ""
}

struct ClassDiagramGraph {
    var classes: [String: ClassBox] = [:]
    var relations: [ClassRelation] = []
    var classOrder: [String] = []
}

// MARK: - Parser

enum MermaidParser {

    static func parse(_ source: String) -> MermaidDiagram? {
        let lines = source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let first = lines.first else { return nil }

        if first.hasPrefix("graph ") || first.hasPrefix("flowchart ") {
            return parseFlowchart(lines)
        } else if first == "sequenceDiagram" {
            return parseSequence(Array(lines.dropFirst()))
        } else if first.hasPrefix("pie") {
            return parsePie(lines.first == "pie" ? Array(lines.dropFirst()) : lines)
        } else if first == "classDiagram" {
            return parseClassDiagram(Array(lines.dropFirst()))
        }
        return nil
    }

    // MARK: Flowchart

    private static func parseFlowchart(_ lines: [String]) -> MermaidDiagram? {
        let parts = lines[0].split(separator: " ")
        let dir: FlowDirection
        switch (parts.count > 1 ? String(parts[1]).uppercased() : "TD") {
        case "LR": dir = .LR
        case "BT": dir = .BT
        case "RL": dir = .RL
        default: dir = .TD
        }
        var graph = FlowchartGraph(direction: dir)

        for line in lines.dropFirst() {
            if line.hasPrefix("subgraph") || line == "end" { continue }
            parseFlowLine(line, graph: &graph)
        }
        return .flowchart(graph)
    }

    private static let edgeOps: [(String, EdgeStyle)] = [
        ("==>", .thick), ("-.->", .dotted), ("-->", .solid), ("---", .plain),
    ]

    private static func parseFlowLine(_ line: String, graph: inout FlowchartGraph) {
        for (op, style) in edgeOps {
            guard let range = line.range(of: op) else { continue }
            let left = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            var right = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            var label = ""
            if right.hasPrefix("|"), let end = right.dropFirst().firstIndex(of: "|") {
                label = String(right[right.index(after: right.startIndex)..<end])
                right = String(right[right.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            }
            let fromId = parseNodeRef(left, graph: &graph)
            let toId = parseNodeRef(right, graph: &graph)
            graph.edges.append(FlowEdge(from: fromId, to: toId, label: label, style: style))
            return
        }
        _ = parseNodeRef(line, graph: &graph)
    }

    private static let nodeRegex = try! NSRegularExpression(
        pattern: #"^([A-Za-z_][A-Za-z0-9_]*)(?:\(\((.+?)\)\)|\(\[(.+?)\]\)|\[(.+?)\]|\((.+?)\)|\{(.+?)\})?\s*$"#
    )

    private static func parseNodeRef(_ ref: String, graph: inout FlowchartGraph) -> String {
        let t = ref.trimmingCharacters(in: .whitespaces)
        let ns = t as NSString
        guard let m = nodeRegex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else {
            let id = t.replacingOccurrences(of: " ", with: "_")
            if graph.nodes[id] == nil {
                graph.nodes[id] = FlowNode(id: id, label: t)
                graph.nodeOrder.append(id)
            }
            return id
        }
        let id = ns.substring(with: m.range(at: 1))
        var label = id
        var shape: NodeShape = .rect

        let groups: [(Int, NodeShape)] = [(2, .circle), (3, .stadium), (4, .rect), (5, .rounded), (6, .diamond)]
        for (g, s) in groups where m.range(at: g).location != NSNotFound {
            label = ns.substring(with: m.range(at: g))
            shape = s
            break
        }

        if graph.nodes[id] == nil {
            graph.nodes[id] = FlowNode(id: id, label: label, shape: shape)
            graph.nodeOrder.append(id)
        } else if label != id {
            graph.nodes[id]?.label = label
            graph.nodes[id]?.shape = shape
        }
        return id
    }

    // MARK: Sequence

    private static func parseSequence(_ lines: [String]) -> MermaidDiagram? {
        var d = SequenceDiagram()
        let arrows: [(String, ArrowType)] = [
            ("-->>", .dashed), ("->>", .solid), ("--x", .cross), ("-x", .cross),
            ("-->", .dashed), ("->", .solid),
        ]
        for line in lines {
            if line.hasPrefix("participant ") {
                let rest = String(line.dropFirst("participant ".count))
                if rest.contains(" as ") {
                    let p = rest.components(separatedBy: " as ")
                    let id = p[0].trimmingCharacters(in: .whitespaces)
                    if !d.participants.contains(id) { d.participants.append(id) }
                    d.participantLabels[id] = p[1].trimmingCharacters(in: .whitespaces)
                } else {
                    let id = rest.trimmingCharacters(in: .whitespaces)
                    if !d.participants.contains(id) { d.participants.append(id) }
                }
                continue
            }
            if ["loop", "alt", "else", "end", "note", "rect", "activate", "deactivate"]
                .contains(where: { line.hasPrefix($0) }) { continue }

            for (arrow, type) in arrows {
                guard let r = line.range(of: arrow) else { continue }
                let from = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rest = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                var to = rest, text = ""
                if let c = rest.firstIndex(of: ":") {
                    to = String(rest[..<c]).trimmingCharacters(in: .whitespaces)
                    text = String(rest[rest.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                }
                if !d.participants.contains(from) { d.participants.append(from) }
                if !d.participants.contains(to) { d.participants.append(to) }
                d.messages.append(SeqMessage(from: from, to: to, text: text, arrowType: type))
                break
            }
        }
        return d.participants.isEmpty ? nil : .sequence(d)
    }

    // MARK: Pie

    private static let pieRegex = try! NSRegularExpression(pattern: #""([^"]+)"\s*:\s*(\d+(?:\.\d+)?)"#)

    private static func parsePie(_ lines: [String]) -> MermaidDiagram? {
        var chart = PieChart()
        for line in lines {
            if line.hasPrefix("title ") {
                chart.title = String(line.dropFirst("title ".count))
                continue
            }
            let ns = line as NSString
            if let m = pieRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let val = Double(ns.substring(with: m.range(at: 2))) {
                chart.slices.append(PieSlice(label: ns.substring(with: m.range(at: 1)), value: val))
            }
        }
        return chart.slices.isEmpty ? nil : .pie(chart)
    }

    // MARK: Class Diagram

    private static func parseClassDiagram(_ lines: [String]) -> MermaidDiagram? {
        var graph = ClassDiagramGraph()
        let relOps: [(String, RelationType)] = [
            ("<|--", .inheritance), ("*--", .composition), ("o--", .aggregation),
            ("..>", .association), ("-->", .association),
        ]

        for line in lines {
            var matched = false
            for (op, type) in relOps {
                guard let r = line.range(of: op) else { continue }
                let from = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rest = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                var to = rest, label = ""
                if let c = rest.firstIndex(of: ":") {
                    to = String(rest[..<c]).trimmingCharacters(in: .whitespaces)
                    label = String(rest[rest.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                }
                ensureClass(from, in: &graph)
                ensureClass(to, in: &graph)
                graph.relations.append(ClassRelation(from: from, to: to, type: type, label: label))
                matched = true
                break
            }
            if matched { continue }

            if line.hasPrefix("class ") {
                let name = String(line.dropFirst("class ".count)).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " {", with: "").replacingOccurrences(of: "{", with: "")
                ensureClass(name, in: &graph)
            } else if line.contains(" : ") {
                let p = line.components(separatedBy: " : ")
                if p.count >= 2 {
                    let cls = p[0].trimmingCharacters(in: .whitespaces)
                    let member = p[1].trimmingCharacters(in: .whitespaces)
                    ensureClass(cls, in: &graph)
                    graph.classes[cls]?.members.append(ClassMember(name: member, isMethod: member.contains("(")))
                }
            }
        }
        return graph.classes.isEmpty ? nil : .classDiagram(graph)
    }

    private static func ensureClass(_ name: String, in graph: inout ClassDiagramGraph) {
        guard graph.classes[name] == nil else { return }
        graph.classes[name] = ClassBox(id: name, name: name)
        graph.classOrder.append(name)
    }
}
