import Compression
import Foundation

enum PNGInfoReader {
    static func read(from fileURL: URL) -> PNGInfo? {
        guard fileURL.pathExtension.lowercased() == "png" else {
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL), data.count > 8 else {
            return nil
        }

        guard data.starts(with: Data([137, 80, 78, 71, 13, 10, 26, 10])) else {
            return nil
        }

        let textEntries = parseTextEntries(from: data)
        guard !textEntries.isEmpty else {
            return nil
        }

        let parameterEntry = textEntries.first {
            $0.keyword.compare("parameters", options: .caseInsensitive) == .orderedSame
        }
        let parsedParameters = parameterEntry.map { parseAutomatic1111Parameters($0.value) }
        let parsedComfyUI = parseComfyUIPrompt(from: textEntries)
        let parsedDrawThings = parseDrawThingsXMP(from: textEntries)

        let prompt = parsedParameters?.prompt ?? parsedComfyUI?.prompt ?? parsedDrawThings?.prompt
        let negativePrompt = parsedParameters?.negativePrompt ?? parsedComfyUI?.negativePrompt ?? parsedDrawThings?.negativePrompt
        let generationParameters = parsedParameters?.parameters ?? parsedComfyUI?.parameters ?? parsedDrawThings?.parameters ?? []
        let hiddenKeywords = (parsedComfyUI?.consumedKeywords ?? []).union(parsedDrawThings?.consumedKeywords ?? [])

        return PNGInfo(
            prompt: prompt,
            negativePrompt: negativePrompt,
            generationParameters: generationParameters,
            textEntries: textEntries.filter { !hiddenKeywords.contains($0.keyword.lowercased()) }
        )
    }

    private static func parseTextEntries(from data: Data) -> [PNGTextEntry] {
        var entries: [PNGTextEntry] = []
        var offset = 8

        while offset + 12 <= data.count {
            guard let length = readUInt32(in: data, at: offset) else {
                break
            }

            let chunkDataStart = offset + 8
            let chunkDataEnd = chunkDataStart + Int(length)
            let chunkEnd = chunkDataEnd + 4

            guard chunkEnd <= data.count else {
                break
            }

            let chunkTypeData = data.subdata(in: (offset + 4)..<chunkDataStart)
            let chunkData = data.subdata(in: chunkDataStart..<chunkDataEnd)
            let chunkType = String(data: chunkTypeData, encoding: .ascii) ?? ""

            switch chunkType {
            case "tEXt":
                if let entry = parseTextChunk(chunkData) {
                    entries.append(entry)
                }
            case "zTXt":
                if let entry = parseCompressedTextChunk(chunkData) {
                    entries.append(entry)
                }
            case "iTXt":
                if let entry = parseInternationalTextChunk(chunkData) {
                    entries.append(entry)
                }
            case "IEND":
                return entries
            default:
                break
            }

            offset = chunkEnd
        }

        return entries
    }

    private static func parseTextChunk(_ data: Data) -> PNGTextEntry? {
        guard let separatorIndex = data.firstIndex(of: 0) else {
            return nil
        }

        let keywordData = data.prefix(upTo: separatorIndex)
        let valueData = data.suffix(from: data.index(after: separatorIndex))

        guard
            let keyword = String(data: keywordData, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !keyword.isEmpty,
            let value = String(data: valueData, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }

        return PNGTextEntry(keyword: keyword, value: value)
    }

    private static func parseCompressedTextChunk(_ data: Data) -> PNGTextEntry? {
        guard let separatorIndex = data.firstIndex(of: 0) else {
            return nil
        }

        let keywordData = data.prefix(upTo: separatorIndex)
        let remaining = data.suffix(from: data.index(after: separatorIndex))

        guard
            let keyword = String(data: keywordData, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !keyword.isEmpty,
            let compressionMethod = remaining.first,
            compressionMethod == 0
        else {
            return nil
        }

        let compressed = Data(remaining.dropFirst())
        guard
            let decompressed = decompressZlib(compressed),
            let value = String(data: decompressed, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }

        return PNGTextEntry(keyword: keyword, value: value)
    }

    private static func parseInternationalTextChunk(_ data: Data) -> PNGTextEntry? {
        guard let keywordEnd = data.firstIndex(of: 0) else {
            return nil
        }

        let keywordData = data.prefix(upTo: keywordEnd)
        guard
            let keyword = String(data: keywordData, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !keyword.isEmpty
        else {
            return nil
        }

        var cursor = data.index(after: keywordEnd)
        guard cursor < data.endIndex else {
            return nil
        }

        let compressionFlag = data[cursor]
        cursor = data.index(after: cursor)
        guard cursor < data.endIndex else {
            return nil
        }

        let compressionMethod = data[cursor]
        cursor = data.index(after: cursor)

        guard let languageEnd = data[cursor...].firstIndex(of: 0) else {
            return nil
        }
        cursor = data.index(after: languageEnd)

        guard let translatedKeywordEnd = data[cursor...].firstIndex(of: 0) else {
            return nil
        }
        cursor = data.index(after: translatedKeywordEnd)

        let textData = Data(data.suffix(from: cursor))
        let decodedText: Data?

        if compressionFlag == 1 {
            guard compressionMethod == 0 else {
                return nil
            }
            decodedText = decompressZlib(textData)
        } else {
            decodedText = textData
        }

        guard
            let decodedText,
            let value = String(data: decodedText, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }

        return PNGTextEntry(keyword: keyword, value: value)
    }

    private static func parseAutomatic1111Parameters(_ value: String) -> (prompt: String?, negativePrompt: String?, parameters: [PNGTextEntry]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (nil, nil, [])
        }

        let negativeLabel = "\nNegative prompt:"
        let parametersLabel = "\nSteps:"

        let prompt: String?
        let negativePrompt: String?
        let parametersText: String?

        if let negativeRange = trimmed.range(of: negativeLabel) {
            prompt = trimmed[..<negativeRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let afterNegativeLabel = trimmed[negativeRange.upperBound...]
            if let parametersRange = afterNegativeLabel.range(of: parametersLabel) {
                negativePrompt = afterNegativeLabel[..<parametersRange.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                parametersText = afterNegativeLabel[parametersRange.lowerBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                negativePrompt = afterNegativeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                parametersText = nil
            }
        } else if let parametersRange = trimmed.range(of: parametersLabel) {
            prompt = trimmed[..<parametersRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            negativePrompt = nil
            parametersText = trimmed[parametersRange.lowerBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            prompt = trimmed
            negativePrompt = nil
            parametersText = nil
        }

        return (
            prompt?.nilIfEmpty,
            negativePrompt?.nilIfEmpty,
            parseParameterEntries(from: parametersText)
        )
    }

    private static func parseComfyUIPrompt(from textEntries: [PNGTextEntry]) -> (prompt: String?, negativePrompt: String?, parameters: [PNGTextEntry], consumedKeywords: Set<String>)? {
        guard
            let promptEntry = textEntries.first(where: { $0.keyword.compare("prompt", options: .caseInsensitive) == .orderedSame }),
            let promptData = promptEntry.value.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: promptData),
            let nodes = json as? [String: [String: Any]]
        else {
            return nil
        }

        let samplerNode = preferredSamplerNode(in: nodes)

        let positivePrompt = samplerNode.flatMap { nodeText(forInput: "positive", in: $0, nodes: nodes) }?.nilIfEmpty
        let negativePrompt = samplerNode.flatMap { nodeText(forInput: "negative", in: $0, nodes: nodes) }?.nilIfEmpty

        var parameters: [PNGTextEntry] = []

        if let checkpoint = firstInputValue(named: "ckpt_name", forClassTypes: ["CheckpointLoaderSimple", "CheckpointLoader", "UNETLoader"], in: nodes) {
            parameters.append(PNGTextEntry(keyword: "Model", value: checkpoint))
        }

        if let samplerNode {
            appendParameter(named: "Seed", input: "seed", from: samplerNode, into: &parameters)
            appendParameter(named: "Steps", input: "steps", from: samplerNode, into: &parameters)
            appendParameter(named: "CFG Scale", input: "cfg", from: samplerNode, into: &parameters)
            appendParameter(named: "Sampler", input: "sampler_name", from: samplerNode, into: &parameters)
            appendParameter(named: "Scheduler", input: "scheduler", from: samplerNode, into: &parameters)
            appendParameter(named: "Denoise", input: "denoise", from: samplerNode, into: &parameters)

            if let latentSize = latentImageSize(for: samplerNode, nodes: nodes) {
                parameters.append(PNGTextEntry(keyword: "Size", value: latentSize))
            }

            if let modelRef = nodeReference(forInput: "model", in: samplerNode, nodes: nodes),
               let modelName = stringInput(named: "ckpt_name", in: modelRef) ?? stringInput(named: "unet_name", in: modelRef),
               !parameters.contains(where: { $0.keyword == "Model" }) {
                parameters.append(PNGTextEntry(keyword: "Model", value: modelName))
            }
        }

        if let imageScale = firstInputValue(named: "scale_by", forClassTypes: ["ImageScaleBy"], in: nodes) {
            parameters.append(PNGTextEntry(keyword: "Upscale", value: imageScale))
        }

        if let upscaleMethod = firstInputValue(named: "upscale_method", forClassTypes: ["ImageScaleBy"], in: nodes) {
            parameters.append(PNGTextEntry(keyword: "Upscale Method", value: upscaleMethod))
        }

        let dedupedParameters = deduplicateEntries(parameters)
        let consumedKeywords = Set(["prompt", "workflow"])

        guard positivePrompt != nil || negativePrompt != nil || !dedupedParameters.isEmpty else {
            return nil
        }

        return (positivePrompt, negativePrompt, dedupedParameters, consumedKeywords)
    }

    private static func parseDrawThingsXMP(from textEntries: [PNGTextEntry]) -> (prompt: String?, negativePrompt: String?, parameters: [PNGTextEntry], consumedKeywords: Set<String>)? {
        guard
            let xmpEntry = textEntries.first(where: isLikelyXMPEntry),
            xmpEntry.value.localizedCaseInsensitiveContains("Draw Things")
        else {
            return nil
        }

        let userCommentJSON = firstTagValue(named: "exif:UserComment", in: xmpEntry.value)
        let altText = firstTagValue(named: "rdf:li", in: xmpEntry.value)

        let parsedJSON = userCommentJSON.flatMap(parseDrawThingsJSON)
        let parsedAltText = altText.flatMap(parseDrawThingsAltText)

        let prompt = parsedJSON?.prompt ?? parsedAltText?.prompt
        let negativePrompt = parsedJSON?.negativePrompt ?? parsedAltText?.negativePrompt
        let parameters = deduplicateEntries(
            (parsedJSON?.parameters ?? []) + (parsedAltText?.parameters ?? [])
        )

        guard prompt != nil || negativePrompt != nil || !parameters.isEmpty else {
            return nil
        }

        return (
            prompt,
            negativePrompt,
            parameters,
            [xmpEntry.keyword.lowercased()]
        )
    }

    private static func parseParameterEntries(from value: String?) -> [PNGTextEntry] {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return []
        }

        return splitParameterSegments(value).compactMap { segment in
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let colonIndex = trimmed.firstIndex(of: ":") else {
                return nil
            }

            let rawKey = trimmed[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)

            guard !rawKey.isEmpty, !rawValue.isEmpty else {
                return nil
            }

            return PNGTextEntry(
                keyword: humanizeParameterKey(String(rawKey)),
                value: humanizeParameterValue(String(rawValue))
            )
        }
    }

    private static func splitParameterSegments(_ value: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var bracketDepth = 0
        var parenDepth = 0
        var braceDepth = 0

        for character in value {
            switch character {
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "(":
                parenDepth += 1
            case ")":
                parenDepth = max(0, parenDepth - 1)
            case "{":
                braceDepth += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
            case "," where bracketDepth == 0 && parenDepth == 0 && braceDepth == 0:
                segments.append(current)
                current.removeAll(keepingCapacity: true)
                continue
            default:
                break
            }

            current.append(character)
        }

        if !current.isEmpty {
            segments.append(current)
        }

        return segments
    }

    private static func humanizeParameterKey(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { part in
                let lowercased = part.lowercased()
                switch lowercased {
                case "cfg":
                    return "CFG"
                case "hires":
                    return "Hires"
                case "eta":
                    return "ETA"
                case "rng":
                    return "RNG"
                case "sd":
                    return "SD"
                default:
                    return lowercased.capitalized
                }
            }
            .joined(separator: " ")
    }

    private static func humanizeParameterValue(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") {
            let inner = cleaned.dropFirst().dropLast()
            let compact = inner
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " x ")
            if !compact.isEmpty {
                return compact
            }
        }

        return cleaned
    }

    private static func isLikelyXMPEntry(_ entry: PNGTextEntry) -> Bool {
        let keyword = entry.keyword.lowercased()
        return keyword.contains("xmp") || entry.value.contains("<x:xmpmeta")
    }

    private static func firstTagValue(named tagName: String, in text: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tagName))\\b[^>]*>(.*?)</\(NSRegularExpression.escapedPattern(for: tagName))>"

        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return decodeXML(text[valueRange]).nilIfEmpty
    }

    private static func decodeXML<S: StringProtocol>(_ value: S) -> String {
        decodeNumericCharacterReferences(
            String(value)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        )
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericCharacterReferences(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else {
            return value
        }

        let nsRange = NSRange(value.startIndex..., in: value)
        var decoded = value

        for match in regex.matches(in: value, range: nsRange).reversed() {
            guard
                let fullRange = Range(match.range(at: 0), in: decoded),
                let codeRange = Range(match.range(at: 1), in: decoded)
            else {
                continue
            }

            let codeText = String(decoded[codeRange])
            let scalarValue: UInt32?

            if codeText.lowercased().hasPrefix("x") {
                scalarValue = UInt32(codeText.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(codeText, radix: 10)
            }

            guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else {
                continue
            }

            decoded.replaceSubrange(fullRange, with: String(scalar))
        }

        return decoded
    }

    private static func parseDrawThingsAltText(_ value: String) -> (prompt: String?, negativePrompt: String?, parameters: [PNGTextEntry]) {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return (nil, nil, [])
        }

        let lines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            return (nil, nil, [])
        }

        let promptLine = lines[0]
        var negativePrompt: String?
        var parameterLines: [String] = []

        for line in lines.dropFirst() {
            if negativePrompt == nil, line.hasPrefix("- ") {
                negativePrompt = String(line.dropFirst(2)).nilIfEmpty
                continue
            }

            if negativePrompt == nil, line.lowercased().hasPrefix("negative prompt:") {
                negativePrompt = line.dropFirst("negative prompt:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                continue
            }

            parameterLines.append(line)
        }

        if negativePrompt == nil, let parameterIndex = parameterLines.firstIndex(where: { $0.contains(":") }) {
            let possibleNegativePrompt = Array(parameterLines[..<parameterIndex])
                .joined(separator: ", ")
                .nilIfEmpty
            negativePrompt = possibleNegativePrompt
            parameterLines = Array(parameterLines[parameterIndex...])
        }

        let parametersText = parameterLines.joined(separator: ", ")

        return (
            promptLine.nilIfEmpty,
            cleanedNegativePrompt(negativePrompt),
            parseParameterEntries(from: parametersText.nilIfEmpty)
        )
    }

    private static func cleanedNegativePrompt(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("-") {
            return value.drop(while: { $0 == "-" || $0.isWhitespace }).nilIfEmpty
        }

        return value.nilIfEmpty
    }

    private static func parseDrawThingsJSON(_ value: String) -> (prompt: String?, negativePrompt: String?, parameters: [PNGTextEntry])? {
        guard
            let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

        let prompt = stringValue(forKeys: ["c", "prompt"], in: dictionary)?.nilIfEmpty
        let negativePrompt = stringValue(forKeys: ["uc", "negative_prompt", "negativePrompt"], in: dictionary)?.nilIfEmpty

        var parameters: [PNGTextEntry] = []

        appendParameter(named: "Model", fromKeys: ["model"], in: dictionary, into: &parameters)
        appendParameter(named: "Seed", fromKeys: ["seed"], in: dictionary, into: &parameters)
        appendParameter(named: "Steps", fromKeys: ["steps"], in: dictionary, into: &parameters)
        appendParameter(named: "Sampler", fromKeys: ["sampler"], in: dictionary, into: &parameters)
        appendParameter(named: "Guidance Scale", fromKeys: ["guidanceScale"], in: dictionary, into: &parameters)
        appendParameter(named: "Strength", fromKeys: ["strength"], in: dictionary, into: &parameters)
        appendParameter(named: "Clip Skip", fromKeys: ["clip_skip", "clipSkip"], in: dictionary, into: &parameters)
        appendParameter(named: "Aesthetic Score", fromKeys: ["aesthetic_score", "aestheticScore"], in: dictionary, into: &parameters)
        appendParameter(named: "Negative Aesthetic Score", fromKeys: ["negative_aesthetic_score", "negativeAestheticScore"], in: dictionary, into: &parameters)
        appendParameter(named: "Original Size", fromKeys: ["original_size", "originalSize"], in: dictionary, into: &parameters)
        appendParameter(named: "Target Size", fromKeys: ["target_size", "targetSize"], in: dictionary, into: &parameters)

        if let width = stringValue(forKeys: ["width"], in: dictionary)?.nilIfEmpty,
           let height = stringValue(forKeys: ["height"], in: dictionary)?.nilIfEmpty {
            parameters.append(PNGTextEntry(keyword: "Size", value: "\(width) x \(height)"))
        }

        return (
            prompt,
            negativePrompt,
            deduplicateEntries(parameters)
        )
    }

    private static func appendParameter(
        named label: String,
        fromKeys keys: [String],
        in dictionary: [String: Any],
        into parameters: inout [PNGTextEntry]
    ) {
        if let value = stringValue(forKeys: keys, in: dictionary)?.nilIfEmpty {
            parameters.append(PNGTextEntry(keyword: label, value: humanizeParameterValue(value)))
        }
    }

    private static func stringValue(forKeys keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let value = stringify(dictionary[key]) {
                return value
            }
        }

        return nil
    }

    private static func preferredSamplerNode(in nodes: [String: [String: Any]]) -> [String: Any]? {
        let preferredTypes = ["KSampler", "KSamplerAdvanced", "SamplerCustom", "SamplerCustomAdvanced"]

        for type in preferredTypes {
            if let node = nodes.values.first(where: { classType(of: $0) == type }) {
                return node
            }
        }

        return nil
    }

    private static func classType(of node: [String: Any]) -> String? {
        node["class_type"] as? String
    }

    private static func inputs(of node: [String: Any]) -> [String: Any] {
        node["inputs"] as? [String: Any] ?? [:]
    }

    private static func stringInput(named key: String, in node: [String: Any]) -> String? {
        let value = inputs(of: node)[key]
        return stringify(value)?.nilIfEmpty
    }

    private static func stringify(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let int as Int:
            return String(int)
        case let double as Double:
            if double.rounded() == double {
                return String(Int(double))
            }
            return String(double)
        case let bool as Bool:
            return bool ? "Yes" : "No"
        default:
            return nil
        }
    }

    private static func appendParameter(named label: String, input key: String, from node: [String: Any], into parameters: inout [PNGTextEntry]) {
        if let value = stringify(inputs(of: node)[key])?.nilIfEmpty {
            parameters.append(PNGTextEntry(keyword: label, value: humanizeParameterValue(value)))
        }
    }

    private static func nodeReference(forInput key: String, in node: [String: Any], nodes: [String: [String: Any]]) -> [String: Any]? {
        guard let reference = inputs(of: node)[key] as? [Any], let nodeID = reference.first else {
            return nil
        }

        let id = String(describing: nodeID)
        return nodes[id]
    }

    private static func nodeText(forInput key: String, in node: [String: Any], nodes: [String: [String: Any]]) -> String? {
        guard let referencedNode = nodeReference(forInput: key, in: node, nodes: nodes) else {
            return nil
        }

        if let text = stringInput(named: "text", in: referencedNode) {
            return text
        }

        return nil
    }

    private static func latentImageSize(for samplerNode: [String: Any], nodes: [String: [String: Any]]) -> String? {
        guard let latentNode = nodeReference(forInput: "latent_image", in: samplerNode, nodes: nodes) else {
            return nil
        }

        let width = stringInput(named: "width", in: latentNode)
        let height = stringInput(named: "height", in: latentNode)

        if let width, let height {
            return "\(width) x \(height)"
        }

        return nil
    }

    private static func firstInputValue(named inputName: String, forClassTypes classTypes: [String], in nodes: [String: [String: Any]]) -> String? {
        for nodeClassType in classTypes {
            if let node = nodes.values.first(where: { classType(of: $0) == nodeClassType }),
               let value = stringInput(named: inputName, in: node) {
                return humanizeParameterValue(value)
            }
        }

        return nil
    }

    private static func deduplicateEntries(_ entries: [PNGTextEntry]) -> [PNGTextEntry] {
        var seen = Set<String>()
        var deduped: [PNGTextEntry] = []

        for entry in entries {
            let key = "\(entry.keyword)\u{1F}\(entry.value)"
            if seen.insert(key).inserted {
                deduped.append(entry)
            }
        }

        return deduped
    }

    private static func readUInt32(in data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else {
            return nil
        }

        return data[offset..<(offset + 4)].reduce(0) { partialResult, byte in
            (partialResult << 8) | UInt32(byte)
        }
    }

    private static func decompressZlib(_ data: Data) -> Data? {
        guard !data.isEmpty else {
            return Data()
        }

        return data.withUnsafeBytes { sourceBuffer in
            guard let sourcePointer = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }

            let destinationCapacity = max(data.count * 8, 4096)
            let destinationPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
            defer { destinationPointer.deallocate() }

            let decompressedSize = compression_decode_buffer(
                destinationPointer,
                destinationCapacity,
                sourcePointer,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )

            guard decompressedSize > 0 else {
                return nil
            }

            return Data(bytes: destinationPointer, count: decompressedSize)
        }
    }
}

private extension StringProtocol {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed)
    }
}
