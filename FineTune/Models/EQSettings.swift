import Foundation

struct EQSettings: Codable, Equatable {
    static let bandCount = 10
    static let maxGainDB: Float = 12.0
    static let minGainDB: Float = -12.0

    /// ISO standard frequencies for 10-band graphic EQ
    static let frequencies: [Double] = [
        31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    ]

    /// Gain in dB for each band (-12 to +12)
    var bandGains: [Float]

    /// Whether EQ processing is enabled
    var isEnabled: Bool

    init(bandGains: [Float] = Array(repeating: 0, count: 10), isEnabled: Bool = true) {
        self.bandGains = bandGains
        self.isEnabled = isEnabled
    }

    /// Returns gains clamped to valid range
    var clampedGains: [Float] {
        bandGains.map { max(Self.minGainDB, min(Self.maxGainDB, $0)) }
    }

    /// Flat EQ preset
    static let flat = EQSettings()
}

struct HeadphoneEQFilter: Codable, Equatable, Sendable {
    var frequencyHz: Double
    var gainDB: Float
    var q: Double

    init(frequencyHz: Double, gainDB: Float, q: Double) {
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
    }
}

struct HeadphoneEQSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var profileName: String
    var sourceFileName: String?
    var filters: [HeadphoneEQFilter]

    init(
        isEnabled: Bool = false,
        profileName: String = "",
        sourceFileName: String? = nil,
        filters: [HeadphoneEQFilter] = []
    ) {
        self.isEnabled = isEnabled
        self.profileName = profileName
        self.sourceFileName = sourceFileName
        self.filters = filters
    }

    var hasProfile: Bool { !filters.isEmpty }

    static let empty = HeadphoneEQSettings()
}

enum AutoEQPEQParser {
    private enum Constants {
        static let maxSupportedFilters = 24
        static let peqLinePattern =
            #"(?i)^\s*filter\s+\d+\s*:\s*on\s+([a-z]+)\s+fc\s+([+-]?(?:\d+\.?\d*|\.\d+))\s*hz\s+gain\s+([+-]?(?:\d+\.?\d*|\.\d+))\s*dB\s+q\s+([+-]?(?:\d+\.?\d*|\.\d+))"#
    }

    enum ParseError: LocalizedError {
        case unreadableFile
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .unreadableFile:
                return "Could not read AutoEQ file."
            case .unsupportedFormat:
                return "No supported ParametricEQ filters were found."
            }
        }
    }

    private static let lineRegex = try! NSRegularExpression(pattern: Constants.peqLinePattern)

    static func parseFile(at url: URL) throws -> HeadphoneEQSettings {
        let didStartSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw ParseError.unreadableFile
        }

        let fallbackName = url.deletingPathExtension().lastPathComponent
        return try parseText(text, fallbackProfileName: fallbackName, sourceFileName: url.lastPathComponent)
    }

    static func parseText(
        _ text: String,
        fallbackProfileName: String,
        sourceFileName: String? = nil
    ) throws -> HeadphoneEQSettings {
        var filters: [HeadphoneEQFilter] = []
        filters.reserveCapacity(10)

        for line in text.components(separatedBy: .newlines) {
            if filters.count >= Constants.maxSupportedFilters { break }

            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = lineRegex.firstMatch(in: line, options: [], range: range),
                  match.numberOfRanges == 5 else {
                continue
            }

            let type = nsLine.substring(with: match.range(at: 1)).lowercased()
            guard type == "pk" || type == "peq" || type == "peak" else {
                continue
            }

            let freqString = nsLine.substring(with: match.range(at: 2))
            let gainString = nsLine.substring(with: match.range(at: 3))
            let qString = nsLine.substring(with: match.range(at: 4))

            guard let frequency = Double(freqString),
                  let gain = Float(gainString),
                  let q = Double(qString),
                  frequency > 0, q > 0 else {
                continue
            }

            filters.append(HeadphoneEQFilter(frequencyHz: frequency, gainDB: gain, q: q))
        }

        guard !filters.isEmpty else {
            throw ParseError.unsupportedFormat
        }

        return HeadphoneEQSettings(
            isEnabled: true,
            profileName: fallbackProfileName,
            sourceFileName: sourceFileName,
            filters: filters
        )
    }
}
