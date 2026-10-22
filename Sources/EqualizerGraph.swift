import SwiftUI

// Adapted from AnimVector, EQGeo and EQCurveShape in uxtigos/qcy-mac,
// copyright (c) 2026 Thiago Oliveira, MIT. See THIRD-PARTY-NOTICES.md.
// Uses interpolation of fixed-band gains, not HT-08 biquad response estimation.
private struct T13GraphVector: VectorArithmetic {
    var values: [Double]
    static var zero: Self { Self(values: []) }
    private static func combine(_ a: Self, _ b: Self, _ op: (Double, Double) -> Double) -> Self {
        Self(values: (0..<max(a.values.count, b.values.count)).map {
            op($0 < a.values.count ? a.values[$0] : 0, $0 < b.values.count ? b.values[$0] : 0)
        })
    }
    static func + (a: Self, b: Self) -> Self { combine(a,b,+) }
    static func - (a: Self, b: Self) -> Self { combine(a,b,-) }
    static func += (a: inout Self, b: Self) { a = a + b }
    static func -= (a: inout Self, b: Self) { a = a - b }
    mutating func scale(by factor: Double) { values = values.map { $0 * factor } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}
private struct T13GraphGeometry {
    let size: CGSize
    let rangeDB: Double
    let left: CGFloat = 24, right: CGFloat = 8, top: CGFloat = 18, labels: CGFloat = 18
    var width: CGFloat { max(1, size.width - left - right) }
    var height: CGFloat { max(1, size.height - top - labels - 5) }
    func x(_ frequency: Double) -> CGFloat { left + CGFloat((log10(frequency) - log10(20)) / 3) * width }
    func y(_ gain: Double) -> CGFloat { top + CGFloat(rangeDB - min(rangeDB,max(-rangeDB,gain))) / (2 * rangeDB) * height }
    func gain(_ y: CGFloat) -> Int { min(Int(rangeDB),max(-Int(rangeDB),Int((rangeDB - Double((y - top) / height) * 2 * rangeDB).rounded()))) }
}
private struct T13CurveShape: Shape {
    var curve: T13GraphVector
    var rangeDB: Double
    var closed = false
    var animatableData: T13GraphVector { get { curve } set { curve = newValue } }
    func path(in rect: CGRect) -> Path {
        let geometry = T13GraphGeometry(size: rect.size, rangeDB: rangeDB)
        return Path { path in
            guard curve.values.count > 1 else { return }
            for index in curve.values.indices {
                let point = CGPoint(x: geometry.left + CGFloat(index) / CGFloat(curve.values.count - 1) * geometry.width, y: geometry.y(curve.values[index]))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            if closed {
                path.addLine(to: CGPoint(x: geometry.left + geometry.width,y: geometry.y(0)))
                path.addLine(to: CGPoint(x: geometry.left,y: geometry.y(0)))
                path.closeSubpath()
            }
        }
    }
}
struct T13EqualizerGraph: View {
    let gains: [Int]
    let rangeDB: Int
    let selected: Int?
    let dragging: Bool
    let reducedMotion: Bool
    let editable: Bool
    let changed: (Int, Int) -> Void
    let ended: () -> Void
    @State private var dragIndex: Int?
    private let curveColor = Color.accentColor
    private let frequencies: [Double] = [31,62,125,250,500,1000,2000,4000,8000,16000]
    private func interpolate(_ frequency: Double) -> Double {
        guard gains.count == 10 else { return 0 }
        if frequency <= frequencies[0] { return Double(gains[0]) }
        if frequency >= frequencies[9] { return Double(gains[9]) }
        for index in 0..<9 where frequency <= frequencies[index + 1] {
            let t = (log10(frequency) - log10(frequencies[index])) / (log10(frequencies[index+1]) - log10(frequencies[index]))
            return Double(gains[index]) + Double(gains[index+1] - gains[index]) * t * t * (3 - 2 * t)
        }
        return 0
    }
    var body: some View {
        let curve = T13GraphVector(values: (0..<120).map { interpolate(pow(10,log10(20) + 3 * Double($0) / 119)) })
        GeometryReader { reader in
            let geometry = T13GraphGeometry(size: reader.size, rangeDB: Double(rangeDB))
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let g = T13GraphGeometry(size: size, rangeDB: Double(rangeDB))
                    for f in frequencies {
                        var path = Path(); path.move(to: CGPoint(x:g.x(f),y:g.top)); path.addLine(to:CGPoint(x:g.x(f),y:g.top+g.height))
                        context.stroke(path,with:.color(.primary.opacity(0.07)),lineWidth:1)
                        let text = f >= 1000 ? "\(Int(f/1000))k" : "\(Int(f))"
                        context.draw(Text(text).font(.system(size:8).monospacedDigit()).foregroundColor(.secondary),at:CGPoint(x:g.x(f),y:size.height-6))
                    }
                    for db in [-rangeDB,0,rangeDB] {
                        var path = Path(); path.move(to:CGPoint(x:g.left,y:g.y(Double(db)))); path.addLine(to:CGPoint(x:g.left+g.width,y:g.y(Double(db))))
                        context.stroke(path,with:.color(.primary.opacity(db == 0 ? 0.18 : 0.07)),lineWidth:1)
                        context.draw(Text(db > 0 ? "+\(db)" : "\(db)").font(.system(size:8).monospacedDigit()).foregroundColor(.secondary),at:CGPoint(x:11,y:g.y(Double(db))))
                    }
                }
                T13CurveShape(curve:curve,rangeDB:Double(rangeDB),closed:true).fill(curveColor.opacity(0.17))
                T13CurveShape(curve:curve,rangeDB:Double(rangeDB)).stroke(curveColor,style:StrokeStyle(lineWidth:1.8,lineCap:.round,lineJoin:.round))
                ForEach(0..<min(gains.count,10), id: \.self) { index in
                    Circle().fill(selected == index ? curveColor : Color(nsColor:.windowBackgroundColor))
                        .overlay(Circle().stroke(selected == index ? curveColor : curveColor,lineWidth:1.5))
                        .frame(width:selected == index ? 9 : 7,height:selected == index ? 9 : 7)
                        .position(x:geometry.x(frequencies[index]),y:geometry.y(Double(gains[index])))
                }
                if let selected, gains.indices.contains(selected), frequencies.indices.contains(selected) {
                    Text("\(Int(frequencies[selected])) Hz · \(gains[selected] > 0 ? "+" : "")\(gains[selected]) dB")
                        .font(.system(size:9,weight:.semibold).monospacedDigit()).fixedSize()
                        .padding(.horizontal,5).padding(.vertical,2).background(.regularMaterial,in:Capsule())
                        .position(x:min(max(geometry.x(frequencies[selected]),65),reader.size.width-65),y:max(8,geometry.y(Double(gains[selected]))-15))
                        .allowsHitTesting(false)
                }
            }
            .animation(dragging || reducedMotion ? nil : .easeInOut(duration:0.35),value:curve)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged { value in
                guard editable, gains.count == 10 else { return }
                if dragIndex == nil {
                    let nearest = (0..<10).min { a,b in
                        hypot(geometry.x(frequencies[a])-value.startLocation.x,geometry.y(Double(gains[a]))-value.startLocation.y) < hypot(geometry.x(frequencies[b])-value.startLocation.x,geometry.y(Double(gains[b]))-value.startLocation.y)
                    }
                    guard let nearest, hypot(geometry.x(frequencies[nearest])-value.startLocation.x,geometry.y(Double(gains[nearest]))-value.startLocation.y) < 24 else { return }
                    dragIndex = nearest
                }
                if let dragIndex { changed(dragIndex,geometry.gain(value.location.y)) }
            }.onEnded { _ in
                guard dragIndex != nil else { return }
                dragIndex = nil; ended()
            },including:editable ? .all : .none)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel("Curva de ganhos do equalizador. No modo Personalizado, use Ajuste preciso por banda para editar com teclado ou VoiceOver.")
        }
    }
}
