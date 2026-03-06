import Foundation

// MARK: - SVG Renderer

enum MermaidRenderer {

    static func renderToSVG(_ diagram: MermaidDiagram) -> String {
        switch diagram {
        case .flowchart(let g): return flowchartSVG(g)
        case .sequence(let s): return sequenceSVG(s)
        case .pie(let p): return pieSVG(p)
        case .classDiagram(let c): return classSVG(c)
        }
    }
}

// MARK: - Colors

private let colors = [
    "#5B8DEF", "#4ECB71", "#F5A623", "#BD6BD6", "#FF6B8A",
    "#4DD0E1", "#FFD54F", "#81C784", "#7986CB", "#4DB6AC",
]
private let nodeFill = "#2A2D3E"
private let nodeStroke = "#5B8DEF"
private let textFill = "#E8E8EC"
private let dimText = "#8E8E93"
private let lineFill = "#5E5E64"

// MARK: - Flowchart

private func flowchartSVG(_ graph: FlowchartGraph) -> String {
    let nodeW: CGFloat = 140
    let nodeH: CGFloat = 42
    let hGap: CGFloat = 50
    let vGap: CGFloat = 60
    let horiz = graph.direction == .LR || graph.direction == .RL

    var adj: [String: [String]] = [:]
    var inDeg: [String: Int] = [:]
    for id in graph.nodeOrder { adj[id] = []; inDeg[id] = 0 }
    for e in graph.edges { adj[e.from, default: []].append(e.to); inDeg[e.to, default: 0] += 1 }

    var layerOf: [String: Int] = [:]
    var queue = graph.nodeOrder.filter { (inDeg[$0] ?? 0) == 0 }
    for id in queue { layerOf[id] = 0 }
    var head = 0
    while head < queue.count {
        let n = queue[head]; head += 1
        for nb in adj[n] ?? [] {
            layerOf[nb] = max(layerOf[nb] ?? 0, (layerOf[n] ?? 0) + 1)
            inDeg[nb] = (inDeg[nb] ?? 1) - 1
            if inDeg[nb] == 0 { queue.append(nb) }
        }
    }
    for id in graph.nodeOrder where layerOf[id] == nil { layerOf[id] = 0 }

    let maxLayer = layerOf.values.max() ?? 0
    var layers = Array(repeating: [String](), count: maxLayer + 1)
    for id in graph.nodeOrder { layers[layerOf[id] ?? 0].append(id) }

    var positions: [String: (x: CGFloat, y: CGFloat)] = [:]
    for (li, layer) in layers.enumerated() {
        for (ni, nodeId) in layer.enumerated() {
            let primary = CGFloat(li) * ((horiz ? nodeW : nodeH) + (horiz ? hGap : vGap)) + (horiz ? nodeW : nodeH) / 2
            let maxInLayer = CGFloat(layer.count)
            let crossSize = (horiz ? nodeH : nodeW) + (horiz ? vGap : hGap)
            let cross = CGFloat(ni) * crossSize + crossSize / 2
            positions[nodeId] = horiz ? (primary, cross) : (cross, primary)
        }
    }

    let pad: CGFloat = 40
    let maxX = positions.values.map(\.x).max() ?? 200
    let maxY = positions.values.map(\.y).max() ?? 200
    let svgW = maxX + nodeW / 2 + pad * 2
    let svgH = maxY + nodeH / 2 + pad * 2

    var svg = svgHeader(width: svgW, height: svgH)
    svg += "<defs><marker id=\"arrow\" viewBox=\"0 0 10 10\" refX=\"10\" refY=\"5\" markerWidth=\"6\" markerHeight=\"6\" orient=\"auto-start-reverse\"><path d=\"M 0 0 L 10 5 L 0 10 z\" fill=\"\(lineFill)\"/></marker></defs>\n"

    for edge in graph.edges {
        guard let fp = positions[edge.from], let tp = positions[edge.to] else { continue }
        let x1 = fp.x + pad, y1 = fp.y + pad, x2 = tp.x + pad, y2 = tp.y + pad
        let dash = edge.style == .dotted ? " stroke-dasharray=\"6,4\"" : ""
        let width = edge.style == .thick ? "3" : "1.5"
        svg += "<line x1=\"\(x1)\" y1=\"\(y1)\" x2=\"\(x2)\" y2=\"\(y2)\" stroke=\"\(lineFill)\" stroke-width=\"\(width)\"\(dash) marker-end=\"url(#arrow)\"/>\n"
        if !edge.label.isEmpty {
            let mx = (x1 + x2) / 2, my = (y1 + y2) / 2 - 10
            svg += "<text x=\"\(mx)\" y=\"\(my)\" text-anchor=\"middle\" fill=\"\(dimText)\" font-size=\"11\" font-family=\"-apple-system, sans-serif\">\(esc(edge.label))</text>\n"
        }
    }

    for (id, node) in graph.nodes {
        guard let pos = positions[id] else { continue }
        let cx = pos.x + pad, cy = pos.y + pad
        switch node.shape {
        case .rect:
            svg += "<rect x=\"\(cx - nodeW/2)\" y=\"\(cy - nodeH/2)\" width=\"\(nodeW)\" height=\"\(nodeH)\" rx=\"6\" fill=\"\(nodeFill)\" stroke=\"\(nodeStroke)\" stroke-width=\"1.5\"/>\n"
        case .rounded, .stadium:
            svg += "<rect x=\"\(cx - nodeW/2)\" y=\"\(cy - nodeH/2)\" width=\"\(nodeW)\" height=\"\(nodeH)\" rx=\"\(nodeH/2)\" fill=\"\(nodeFill)\" stroke=\"\(nodeStroke)\" stroke-width=\"1.5\"/>\n"
        case .diamond:
            let hw = nodeW / 2, hh = nodeH / 2
            svg += "<polygon points=\"\(cx),\(cy - hh) \(cx + hw),\(cy) \(cx),\(cy + hh) \(cx - hw),\(cy)\" fill=\"\(nodeFill)\" stroke=\"\(nodeStroke)\" stroke-width=\"1.5\"/>\n"
        case .circle:
            let r = max(nodeW, nodeH) / 2.2
            svg += "<circle cx=\"\(cx)\" cy=\"\(cy)\" r=\"\(r)\" fill=\"\(nodeFill)\" stroke=\"\(nodeStroke)\" stroke-width=\"1.5\"/>\n"
        }
        svg += "<text x=\"\(cx)\" y=\"\(cy + 4)\" text-anchor=\"middle\" fill=\"\(textFill)\" font-size=\"12\" font-weight=\"500\" font-family=\"-apple-system, sans-serif\">\(esc(node.label))</text>\n"
    }

    svg += "</svg>"
    return svg
}

// MARK: - Sequence Diagram

private func sequenceSVG(_ diagram: SequenceDiagram) -> String {
    let boxW: CGFloat = 110
    let boxH: CGFloat = 34
    let spacing: CGFloat = 150
    let msgGap: CGFloat = 50
    let topPad: CGFloat = 20

    let totalW = CGFloat(diagram.participants.count) * spacing + 20
    let totalH = topPad + boxH + CGFloat(diagram.messages.count + 1) * msgGap + 30

    func xOf(_ id: String) -> CGFloat {
        let idx = diagram.participants.firstIndex(of: id) ?? 0
        return CGFloat(idx) * spacing + spacing / 2 + 10
    }

    var svg = svgHeader(width: totalW, height: totalH)
    svg += "<defs><marker id=\"seq-arrow\" viewBox=\"0 0 10 10\" refX=\"10\" refY=\"5\" markerWidth=\"6\" markerHeight=\"6\" orient=\"auto-start-reverse\"><path d=\"M 0 0 L 10 5 L 0 10 z\" fill=\"\(lineFill)\"/></marker></defs>\n"

    for id in diagram.participants {
        let x = xOf(id)
        let label = diagram.participantLabels[id] ?? id
        svg += "<rect x=\"\(x - boxW/2)\" y=\"\(topPad)\" width=\"\(boxW)\" height=\"\(boxH)\" rx=\"6\" fill=\"\(nodeFill)\" stroke=\"\(nodeStroke)\" stroke-width=\"1.5\"/>\n"
        svg += "<text x=\"\(x)\" y=\"\(topPad + boxH/2 + 4)\" text-anchor=\"middle\" fill=\"\(textFill)\" font-size=\"12\" font-weight=\"600\" font-family=\"-apple-system, sans-serif\">\(esc(label))</text>\n"
        svg += "<line x1=\"\(x)\" y1=\"\(topPad + boxH)\" x2=\"\(x)\" y2=\"\(totalH - 10)\" stroke=\"\(lineFill)\" stroke-width=\"1\" stroke-dasharray=\"5,4\" opacity=\"0.4\"/>\n"
    }

    for (i, msg) in diagram.messages.enumerated() {
        let y = topPad + boxH + CGFloat(i + 1) * msgGap
        let fromX = xOf(msg.from)
        let toX = xOf(msg.to)
        let dash = msg.arrowType == .dashed ? " stroke-dasharray=\"6,3\"" : ""
        svg += "<line x1=\"\(fromX)\" y1=\"\(y)\" x2=\"\(toX)\" y2=\"\(y)\" stroke=\"\(lineFill)\" stroke-width=\"1.5\"\(dash) marker-end=\"url(#seq-arrow)\"/>\n"
        if !msg.text.isEmpty {
            let mx = (fromX + toX) / 2
            svg += "<text x=\"\(mx)\" y=\"\(y - 8)\" text-anchor=\"middle\" fill=\"\(dimText)\" font-size=\"11\" font-family=\"-apple-system, sans-serif\">\(esc(msg.text))</text>\n"
        }
    }

    svg += "</svg>"
    return svg
}

// MARK: - Pie Chart

private func pieSVG(_ chart: PieChart) -> String {
    let radius: CGFloat = 100
    let cx: CGFloat = 140
    let cy: CGFloat = (chart.title.isEmpty ? 0 : 30) + radius + 20
    let total = chart.slices.reduce(0.0) { $0 + $1.value }
    guard total > 0 else { return "" }

    let legendY = cy + radius + 25
    let svgW: CGFloat = 300
    let svgH = legendY + CGFloat(chart.slices.count) * 20 + 10

    var svg = svgHeader(width: svgW, height: svgH)

    if !chart.title.isEmpty {
        svg += "<text x=\"\(cx)\" y=\"24\" text-anchor=\"middle\" fill=\"\(textFill)\" font-size=\"14\" font-weight=\"600\" font-family=\"-apple-system, sans-serif\">\(esc(chart.title))</text>\n"
    }

    var startAngle: CGFloat = -90
    for (i, slice) in chart.slices.enumerated() {
        let sweep = 360 * CGFloat(slice.value / total)
        let endAngle = startAngle + sweep
        let largeArc = sweep > 180 ? 1 : 0
        let rad1 = startAngle * .pi / 180
        let rad2 = endAngle * .pi / 180
        let x1 = cx + radius * cos(rad1)
        let y1 = cy + radius * sin(rad1)
        let x2 = cx + radius * cos(rad2)
        let y2 = cy + radius * sin(rad2)
        let color = colors[i % colors.count]
        svg += "<path d=\"M \(cx) \(cy) L \(x1) \(y1) A \(radius) \(radius) 0 \(largeArc) 1 \(x2) \(y2) Z\" fill=\"\(color)\" opacity=\"0.85\"/>\n"
        startAngle = endAngle

        let ly = legendY + CGFloat(i) * 20
        svg += "<rect x=\"20\" y=\"\(ly - 8)\" width=\"12\" height=\"12\" rx=\"2\" fill=\"\(color)\"/>\n"
        let pct = Int(round(slice.value / total * 100))
        svg += "<text x=\"40\" y=\"\(ly + 3)\" fill=\"\(dimText)\" font-size=\"12\" font-family=\"-apple-system, sans-serif\">\(esc(slice.label)) (\(pct)%)</text>\n"
    }

    svg += "</svg>"
    return svg
}

// MARK: - Class Diagram

private func classSVG(_ graph: ClassDiagramGraph) -> String {
    let boxW: CGFloat = 170
    let headerH: CGFloat = 32
    let memberH: CGFloat = 20
    let cols = 3
    let hGap: CGFloat = 50
    let vGap: CGFloat = 40
    let pad: CGFloat = 20

    let classes = graph.classOrder.compactMap { graph.classes[$0] }
    let rows = (classes.count + cols - 1) / cols

    func boxHeight(_ cls: ClassBox) -> CGFloat { headerH + CGFloat(max(cls.members.count, 1)) * memberH + 8 }
    func origin(_ idx: Int) -> (x: CGFloat, y: CGFloat) {
        let col = idx % cols
        let row = idx / cols
        return (pad + CGFloat(col) * (boxW + hGap), pad + CGFloat(row) * (120 + vGap))
    }

    let svgW = pad * 2 + CGFloat(min(classes.count, cols)) * (boxW + hGap)
    let svgH = pad * 2 + CGFloat(rows) * (120 + vGap)

    var svg = svgHeader(width: svgW, height: svgH)
    svg += "<defs><marker id=\"cls-arrow\" viewBox=\"0 0 10 10\" refX=\"10\" refY=\"5\" markerWidth=\"6\" markerHeight=\"6\" orient=\"auto-start-reverse\"><path d=\"M 0 0 L 10 5 L 0 10 z\" fill=\"\(lineFill)\"/></marker></defs>\n"

    var centers: [String: (x: CGFloat, y: CGFloat)] = [:]

    for (i, cls) in classes.enumerated() {
        let o = origin(i)
        let bh = boxHeight(cls)
        svg += "<rect x=\"\(o.x)\" y=\"\(o.y)\" width=\"\(boxW)\" height=\"\(bh)\" rx=\"6\" fill=\"\(nodeFill)\" stroke=\"\(nodeStroke)\" stroke-width=\"1.5\"/>\n"
        svg += "<text x=\"\(o.x + boxW/2)\" y=\"\(o.y + headerH/2 + 5)\" text-anchor=\"middle\" fill=\"\(textFill)\" font-size=\"12\" font-weight=\"700\" font-family=\"-apple-system, sans-serif\">\(esc(cls.name))</text>\n"
        svg += "<line x1=\"\(o.x)\" y1=\"\(o.y + headerH)\" x2=\"\(o.x + boxW)\" y2=\"\(o.y + headerH)\" stroke=\"\(nodeStroke)\" opacity=\"0.4\"/>\n"
        for (j, member) in cls.members.enumerated() {
            let my = o.y + headerH + 4 + CGFloat(j) * memberH
            svg += "<text x=\"\(o.x + 10)\" y=\"\(my + 14)\" fill=\"\(dimText)\" font-size=\"11\" font-family=\"'SF Mono', Menlo, monospace\">\(esc(member.name))</text>\n"
        }
        centers[cls.id] = (o.x + boxW / 2, o.y + bh / 2)
    }

    for rel in graph.relations {
        guard let fp = centers[rel.from], let tp = centers[rel.to] else { continue }
        svg += "<line x1=\"\(fp.x)\" y1=\"\(fp.y)\" x2=\"\(tp.x)\" y2=\"\(tp.y)\" stroke=\"\(lineFill)\" stroke-width=\"1.5\" marker-end=\"url(#cls-arrow)\"/>\n"
    }

    svg += "</svg>"
    return svg
}

// MARK: - Helpers

private func svgHeader(width: CGFloat, height: CGFloat) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Int(width))\" height=\"\(Int(height))\" viewBox=\"0 0 \(Int(width)) \(Int(height))\">\n<rect width=\"100%\" height=\"100%\" fill=\"#1C1C1E\" rx=\"10\"/>\n"
}

private func esc(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
