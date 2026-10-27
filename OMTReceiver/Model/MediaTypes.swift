import Foundation

struct OMTSource: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let address: String
    static let testPattern = OMTSource(id: "builtin:pattern", name: "Test Pattern", address: "builtin:pattern")
    static func manual(_ text: String) throws -> OMTSource {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = value.contains("://") ? value : "omt://\(value)"
        guard !value.contains(where: \.isWhitespace), let c = URLComponents(string: address),
              c.scheme?.lowercased() == "omt", let host = c.host, !host.isEmpty,
              let port = c.port, (1...65535).contains(port), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else {
            throw OMTError.invalidAddress
        }
        return OMTSource(id: address, name: "\(host):\(port)", address: address)
    }
}

enum OMTError: LocalizedError {
    case invalidAddress
    var errorDescription: String? { "Enter an address with the sender’s actual port, such as omt://192.168.1.20:6400 or omt://[::1]:6400." }
}

enum DeinterlaceMode: String, CaseIterable { case automatic, bob, weave
    var title: String { switch self { case .automatic: return "Automatic"; case .bob: return "Deinterlace (Field Rate)"; case .weave: return "Preserve Fields (Weave)" } }
}
enum FieldOrder: String, CaseIterable { case topFirst, bottomFirst
    var title: String { self == .topFirst ? "Top Field First" : "Bottom Field First" }
}
enum VideoBackground: String, CaseIterable { case black, checkerboard, white
    var title: String { rawValue.capitalized }
}

/// Owns a copy of SDK memory. The SDK's pointers expire on the next receive call.
struct VideoFrame: Sendable {
    let width: Int
    let height: Int
    let stride: Int
    let codec: UInt32
    let flags: Int
    let frameRateN: Int
    let frameRateD: Int
    let aspectRatio: Double
    let colorSpace: Int
    let timestamp: Int64
    let receivedAt: TimeInterval
    let data: Data
    var isInterlaced: Bool { flags & 1 != 0 }
    var hasAlpha: Bool { flags & 2 != 0 }
    var isPremultiplied: Bool { flags & 4 != 0 }
    var framesPerSecond: Double { Double(frameRateN) / Double(max(1, frameRateD)) }
    var displayAspect: Double { aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : Double(width) / Double(max(1, height)) }
    var summary: String {
        let rate = String(format: "%.3f", framesPerSecond).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        let color = colorSpace == 601 || (colorSpace == 0 && height < 720) ? "Rec.601" : "Rec.709"
        return "\(width) × \(height)\(isInterlaced ? "i" : "p") · \(rate) fps\(isInterlaced ? " (\(String(format: "%.2f", framesPerSecond * 2)) fields/s)" : "") · \(color)\(hasAlpha ? " · Alpha" : "")"
    }
}

struct AudioFrame: Sendable {
    let sampleRate: Double
    let channels: Int
    let samplesPerChannel: Int
    let timestamp: Int64
    let data: Data
}
