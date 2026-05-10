import Compression
import Foundation

enum MetadataReader {
    // MARK: - Public API

    static func read(image url: URL) -> ImageMetadata? {
        guard url.pathExtension.lowercased() == "png" else { return nil }

        guard
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
            fileSize > pngSignature.count,
            fileSize <= maximumFileSize
        else { return nil }

        guard
            let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            data.count > pngSignature.count,
            data.count <= maximumFileSize,
            data.starts(with: pngSignature)
        else { return nil }

        let textEntries = parsePNGTextEntries(from: data)
        guard !textEntries.isEmpty else { return nil }

        let parameterEntry = textEntries.first {
            $0.keyword.compare("parameters", options: .caseInsensitive) == .orderedSame
        }
        let parsedA1111 = parameterEntry.map { parseA1111($0.value) }
        let parsedComfyUI = parseComfyUI(from: textEntries)
        let parsedDrawThings = parseDrawThingsXMP(from: textEntries)

        let prompt = parsedA1111?.prompt ?? parsedComfyUI?.prompt ?? parsedDrawThings?.prompt
        let negativePrompt = parsedA1111?.negativePrompt ?? parsedComfyUI?.negativePrompt ?? parsedDrawThings?.negativePrompt
        let promptStatusMessage = parsedComfyUI?.promptStatusMessage
        let generationParameters = parsedA1111?.parameters ?? parsedComfyUI?.parameters ?? parsedDrawThings?.parameters ?? []
        let hiddenKeywords = (parsedComfyUI?.consumedKeywords ?? []).union(parsedDrawThings?.consumedKeywords ?? [])

        return ImageMetadata(
            prompt: prompt,
            negativePrompt: negativePrompt,
            promptStatusMessage: promptStatusMessage,
            generationParameters: generationParameters,
            textEntries: textEntries.filter { !hiddenKeywords.contains($0.keyword.lowercased()) }
        )
    }

    static func read(infotext text: String) -> ImageMetadata? {
        let parsed = parseA1111(text)
        guard parsed.prompt != nil || !parsed.parameters.isEmpty else { return nil }
        let meta = ImageMetadata(
            prompt: parsed.prompt, negativePrompt: parsed.negativePrompt,
            promptStatusMessage: nil,
            generationParameters: parsed.parameters, textEntries: []
        )
        return meta.hasVisibleContent ? meta : nil
    }

    static func readSidecar(for imageURL: URL) -> ImageMetadata? {
        let sidecarURL = imageURL.deletingPathExtension().appendingPathExtension("txt")
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: sidecarURL.path),
            let size = attrs[.size] as? Int, size > 0, size <= maximumMetadataFileSize,
            let text = try? String(contentsOf: sidecarURL, encoding: .utf8)
        else { return nil }
        return read(infotext: text)
    }

    static func read(folder url: URL) -> ImageMetadata? {
        let fileManager = FileManager.default
        for fileName in supportedFolderFileNames {
            let fileURL = url.appendingPathComponent(fileName, isDirectory: false)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            switch fileURL.pathExtension.lowercased() {
            case "json":
                if let metadata = readJSON(from: fileURL) { return metadata }
            case "cfg":
                if let metadata = readCFG(from: fileURL) { return metadata }
            default:
                break
            }
        }
        return nil
    }

    // MARK: - PNG limits

    private static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    private static let maximumFileSize = 128 * 1_024 * 1_024
    private static let maximumChunkDataLength = 8 * 1_024 * 1_024
    private static let maximumTextEntryCount = 64
    private static let maximumKeywordLength = 80
    private static let maximumTextValueLength = 1 * 1_024 * 1_024
    private static let maximumCompressedTextLength = 4 * 1_024 * 1_024
    private static let maximumTotalTextBytes = 8 * 1_024 * 1_024
    private static let maximumDecompressedTextLength = 1 * 1_024 * 1_024

    // MARK: - Folder limits

    private static let maximumMetadataFileSize = 1 * 1_024 * 1_024
    private static let supportedFolderFileNames = [
        "aigallery.json", "aigallery.cfg", "metadata.json", "metadata.cfg"
    ]

    // MARK: - Shared utilities

    // Scalar-only: used by ComfyUI node helpers where [Any] = node reference, not displayable text.
    private static func stringify(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        case let int as Int:
            return String(int)
        case let double as Double:
            if double.rounded() == double { return String(Int(double)) }
            return String(double)
        case let bool as Bool:
            return bool ? "Yes" : "No"
        default:
            return nil
        }
    }

    // Array-aware: used by folder metadata helpers where [Any] is a legitimate displayable list.
    private static func stringifyValue(_ value: Any?) -> String? {
        if let array = value as? [Any] {
            let parts = array.compactMap(stringify)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        return stringify(value)
    }

    private static func stringValue(forKeys keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let value = dictionary[key], let stringified = stringify(value) {
                return stringified
            }
        }
        return nil
    }

    private static func humanizeKey(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in
                let lowercased = part.lowercased()
                switch lowercased {
                case "cfg":   return "CFG"
                case "vae":   return "VAE"
                case "hires": return "Hires"
                case "eta":   return "ETA"
                case "rng":   return "RNG"
                case "sd":    return "SD"
                default:      return lowercased.capitalized
                }
            }
            .joined(separator: " ")
    }

    private static func deduplicate(_ entries: [PNGTextEntry]) -> [PNGTextEntry] {
        var seen = Set<String>()
        var deduped: [PNGTextEntry] = []
        for entry in entries {
            let key = "\(entry.keyword.lowercased())\u{1F}\(entry.value)"
            if seen.insert(key).inserted { deduped.append(entry) }
        }
        return deduped
    }

    // MARK: - PNG chunk parsing

    private static func parsePNGTextEntries(from data: Data) -> [PNGTextEntry] {
        var entries: [PNGTextEntry] = []
        var offset = 8
        var totalTextBytes = 0

        while offset + 12 <= data.count {
            guard let length = readUInt32(in: data, at: offset) else { break }
            let chunkLength = Int(length)
            guard chunkLength <= maximumChunkDataLength else { break }

            let chunkDataStart = offset + 8
            let chunkDataEnd = chunkDataStart + chunkLength
            let chunkEnd = chunkDataEnd + 4
            guard chunkEnd <= data.count else { break }

            let chunkTypeData = data.subdata(in: (offset + 4)..<chunkDataStart)
            let chunkData = data.subdata(in: chunkDataStart..<chunkDataEnd)
            let chunkType = String(data: chunkTypeData, encoding: .ascii) ?? ""

            switch chunkType {
            case "tEXt":
                if let entry = parseTextChunk(chunkData) {
                    entries.append(entry)
                    totalTextBytes += entry.keyword.utf8.count + entry.value.utf8.count
                }
            case "zTXt":
                if let entry = parseCompressedTextChunk(chunkData) {
                    entries.append(entry)
                    totalTextBytes += entry.keyword.utf8.count + entry.value.utf8.count
                }
            case "iTXt":
                if let entry = parseInternationalTextChunk(chunkData) {
                    entries.append(entry)
                    totalTextBytes += entry.keyword.utf8.count + entry.value.utf8.count
                }
            case "IEND":
                return entries
            default:
                break
            }

            if entries.count >= maximumTextEntryCount || totalTextBytes >= maximumTotalTextBytes { break }
            offset = chunkEnd
        }

        return entries
    }

    private static func parseTextChunk(_ data: Data) -> PNGTextEntry? {
        guard let sep = data.firstIndex(of: 0) else { return nil }
        let keywordData = data.prefix(upTo: sep)
        let valueData = data.suffix(from: data.index(after: sep))
        guard keywordData.count <= maximumKeywordLength, valueData.count <= maximumTextValueLength else { return nil }
        guard
            let keyword = String(data: keywordData, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !keyword.isEmpty,
            let value = String(data: valueData, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return PNGTextEntry(keyword: keyword, value: value)
    }

    private static func parseCompressedTextChunk(_ data: Data) -> PNGTextEntry? {
        guard let sep = data.firstIndex(of: 0) else { return nil }
        let keywordData = data.prefix(upTo: sep)
        let remaining = data.suffix(from: data.index(after: sep))
        guard keywordData.count <= maximumKeywordLength else { return nil }
        guard
            let keyword = String(data: keywordData, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !keyword.isEmpty,
            let compressionMethod = remaining.first,
            compressionMethod == 0
        else { return nil }
        let compressed = Data(remaining.dropFirst())
        guard
            compressed.count <= maximumCompressedTextLength,
            let decompressed = decompressZlib(compressed, maximumOutputSize: maximumDecompressedTextLength),
            let value = String(data: decompressed, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return PNGTextEntry(keyword: keyword, value: value)
    }

    private static func parseInternationalTextChunk(_ data: Data) -> PNGTextEntry? {
        guard let keywordEnd = data.firstIndex(of: 0) else { return nil }
        let keywordData = data.prefix(upTo: keywordEnd)
        guard keywordData.count <= maximumKeywordLength else { return nil }
        guard
            let keyword = String(data: keywordData, encoding: .isoLatin1)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !keyword.isEmpty
        else { return nil }

        var cursor = data.index(after: keywordEnd)
        guard cursor < data.endIndex else { return nil }
        let compressionFlag = data[cursor]
        cursor = data.index(after: cursor)
        guard cursor < data.endIndex else { return nil }
        let compressionMethod = data[cursor]
        cursor = data.index(after: cursor)

        guard let languageEnd = data[cursor...].firstIndex(of: 0) else { return nil }
        cursor = data.index(after: languageEnd)
        guard let translatedKeywordEnd = data[cursor...].firstIndex(of: 0) else { return nil }
        cursor = data.index(after: translatedKeywordEnd)

        let textData = Data(data.suffix(from: cursor))
        let decodedText: Data?

        if compressionFlag == 1 {
            guard compressionMethod == 0, textData.count <= maximumCompressedTextLength else { return nil }
            decodedText = decompressZlib(textData, maximumOutputSize: maximumDecompressedTextLength)
        } else {
            guard textData.count <= maximumTextValueLength else { return nil }
            decodedText = textData
        }

        guard
            let decodedText,
            decodedText.count <= maximumDecompressedTextLength,
            let value = String(data: decodedText, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return PNGTextEntry(keyword: keyword, value: value)
    }

    private static func readUInt32(in data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func decompressZlib(_ data: Data, maximumOutputSize: Int) -> Data? {
        guard !data.isEmpty, maximumOutputSize > 0 else { return data.isEmpty ? Data() : nil }

        return data.withUnsafeBytes { sourceBuffer -> Data? in
            guard let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }

            let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { streamPtr.deallocate() }
            var stream = streamPtr.pointee
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { return nil }
            defer { compression_stream_destroy(&stream) }

            stream.src_ptr = sourceBase
            stream.src_size = data.count

            let capacity = min(max(data.count * 4, 4096), maximumOutputSize)
            let destPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destPtr.deallocate() }

            var output = Data()

            while true {
                stream.dst_ptr = destPtr
                stream.dst_size = capacity
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = capacity - stream.dst_size
                if produced > 0 {
                    if output.count + produced > maximumOutputSize { return nil }
                    output.append(destPtr, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_OK:
                    if stream.dst_size == 0 && output.count >= maximumOutputSize { return nil }
                    continue
                case COMPRESSION_STATUS_END:
                    return output
                default:
                    return nil
                }
            }
        }
    }

    // MARK: - A1111 format

    private static func parseA1111(_ value: String) -> (prompt: String?, negativePrompt: String?, parameters: [PNGTextEntry]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil, []) }

        let negativeLabel = "\nNegative prompt:"
        let parametersLabel = "\nSteps:"

        let prompt: String?
        let negativePrompt: String?
        let parametersText: String?

        if let negRange = trimmed.range(of: negativeLabel) {
            prompt = trimmed[..<negRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let afterNeg = trimmed[negRange.upperBound...]
            if let paramsRange = afterNeg.range(of: parametersLabel) {
                negativePrompt = afterNeg[..<paramsRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                parametersText = afterNeg[paramsRange.lowerBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                negativePrompt = afterNeg.trimmingCharacters(in: .whitespacesAndNewlines)
                parametersText = nil
            }
        } else if let paramsRange = trimmed.range(of: parametersLabel) {
            prompt = trimmed[..<paramsRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            negativePrompt = nil
            parametersText = trimmed[paramsRange.lowerBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            prompt = trimmed
            negativePrompt = nil
            parametersText = nil
        }

        return (prompt?.nilIfEmpty, negativePrompt?.nilIfEmpty, parseA1111ParameterEntries(from: parametersText))
    }

    private static func parseA1111ParameterEntries(from value: String?) -> [PNGTextEntry] {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return [] }

        return splitParameterSegments(value).compactMap { segment in
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let colonIndex = trimmed.firstIndex(of: ":") else { return nil }
            let rawKey = trimmed[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawKey.isEmpty, !rawValue.isEmpty else { return nil }
            return PNGTextEntry(keyword: humanizeKey(String(rawKey)), value: humanizeParameterValue(String(rawValue)))
        }
    }

    private static func splitParameterSegments(_ value: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var bracketDepth = 0
        var parenDepth = 0
        var braceDepth = 0

        for ch in value {
            switch ch {
            case "[": bracketDepth += 1
            case "]": bracketDepth = max(0, bracketDepth - 1)
            case "(": parenDepth += 1
            case ")": parenDepth = max(0, parenDepth - 1)
            case "{": braceDepth += 1
            case "}": braceDepth = max(0, braceDepth - 1)
            case "," where bracketDepth == 0 && parenDepth == 0 && braceDepth == 0:
                segments.append(current)
                current.removeAll(keepingCapacity: true)
                continue
            default: break
            }
            current.append(ch)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func humanizeParameterValue(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("[") && cleaned.hasSuffix("]") {
            let inner = cleaned.dropFirst().dropLast()
            let compact = inner.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " x ")
            if !compact.isEmpty { return compact }
        }
        return cleaned
    }

    // MARK: - ComfyUI format

    private static func parseComfyUI(from textEntries: [PNGTextEntry]) -> (prompt: String?, negativePrompt: String?, promptStatusMessage: String?, parameters: [PNGTextEntry], consumedKeywords: Set<String>)? {
        guard let promptEntry = textEntries.first(where: { $0.keyword.compare("prompt", options: .caseInsensitive) == .orderedSame }) else { return nil }

        let sanitized = promptEntry.value
            .replacingOccurrences(of: #"\bNaN\b"#, with: "null", options: .regularExpression)
            .replacingOccurrences(of: #"\bInfinity\b"#, with: "null", options: .regularExpression)

        guard
            let promptData = sanitized.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: promptData),
            let nodes = json as? [String: [String: Any]]
        else { return nil }

        let samplerNode = primarySamplerNode(in: nodes)
        let positivePrompt = samplerNode.flatMap { nodeText(forInput: "positive", in: $0, nodes: nodes) }?.nilIfEmpty
        let negativePrompt = samplerNode.flatMap { nodeText(forInput: "negative", in: $0, nodes: nodes) }?.nilIfEmpty

        var parameters: [PNGTextEntry] = []
        if let checkpoint = firstInputValue(named: "ckpt_name", forClassTypes: ["CheckpointLoaderSimple", "CheckpointLoader", "UNETLoader"], in: nodes) {
            parameters.append(PNGTextEntry(keyword: "Model", value: checkpoint))
        }
        if let samplerNode {
            appendParameter(named: "Seed", input: "seed", from: samplerNode, into: &parameters)
            if !parameters.contains(where: { $0.keyword == "Seed" }) {
                appendParameter(named: "Seed", input: "noise_seed", from: samplerNode, into: &parameters)
            }
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

        let promptStatusMessage = positivePrompt == nil ? "Unable to reconstruct prompt from ComfyUI nodes" : nil
        return (positivePrompt, negativePrompt, promptStatusMessage, deduplicate(parameters), Set(["prompt", "workflow"]))
    }

    // MARK: - Draw Things format

    private static func parseDrawThingsXMP(from textEntries: [PNGTextEntry]) -> (prompt: String?, negativePrompt: String?, parameters: [PNGTextEntry], consumedKeywords: Set<String>)? {
        guard
            let xmpEntry = textEntries.first(where: isLikelyXMPEntry),
            xmpEntry.value.localizedCaseInsensitiveContains("Draw Things")
        else { return nil }

        let parsedJSON = firstTagValue(named: "exif:UserComment", in: xmpEntry.value).flatMap(parseDrawThingsJSON)
        let parsedAltText = firstTagValue(named: "rdf:li", in: xmpEntry.value).flatMap(parseDrawThingsAltText)

        let prompt = parsedJSON?.prompt ?? parsedAltText?.prompt
        let negativePrompt = parsedJSON?.negativePrompt ?? parsedAltText?.negativePrompt
        let parameters = deduplicate((parsedJSON?.parameters ?? []) + (parsedAltText?.parameters ?? []))

        guard prompt != nil || negativePrompt != nil || !parameters.isEmpty else { return nil }
        return (prompt, negativePrompt, parameters, [xmpEntry.keyword.lowercased()])
    }

    private static func isLikelyXMPEntry(_ entry: PNGTextEntry) -> Bool {
        entry.keyword.lowercased().contains("xmp") || entry.value.contains("<x:xmpmeta")
    }

    private static func firstTagValue(named tagName: String, in text: String) -> String? {
        let pattern = "<\(NSRegularExpression.escapedPattern(for: tagName))\\b[^>]*>(.*?)</\(NSRegularExpression.escapedPattern(for: tagName))>"
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let valueRange = Range(match.range(at: 1), in: text)
        else { return nil }
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
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else { return value }
        var decoded = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard
                let fullRange = Range(match.range(at: 0), in: decoded),
                let codeRange = Range(match.range(at: 1), in: decoded)
            else { continue }
            let codeText = String(decoded[codeRange])
            let scalarValue = codeText.lowercased().hasPrefix("x")
                ? UInt32(codeText.dropFirst(), radix: 16)
                : UInt32(codeText, radix: 10)
            guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else { continue }
            decoded.replaceSubrange(fullRange, with: String(scalar))
        }
        return decoded
    }

    private static func parseDrawThingsAltText(_ value: String) -> (prompt: String?, negativePrompt: String?, parameters: [PNGTextEntry]) {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return (nil, nil, []) }

        let lines = normalized.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return (nil, nil, []) }

        let promptLine = lines[0]
        var negativePrompt: String?
        var parameterLines: [String] = []

        for line in lines.dropFirst() {
            if negativePrompt == nil, line.hasPrefix("- ") {
                negativePrompt = String(line.dropFirst(2)).nilIfEmpty; continue
            }
            if negativePrompt == nil, line.lowercased().hasPrefix("negative prompt:") {
                negativePrompt = line.dropFirst("negative prompt:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                continue
            }
            parameterLines.append(line)
        }

        if negativePrompt == nil, let pi = parameterLines.firstIndex(where: { $0.contains(":") }) {
            negativePrompt = Array(parameterLines[..<pi]).joined(separator: ", ").nilIfEmpty
            parameterLines = Array(parameterLines[pi...])
        }

        return (
            promptLine.nilIfEmpty,
            cleanedNegativePrompt(negativePrompt),
            parseA1111ParameterEntries(from: parameterLines.joined(separator: ", ").nilIfEmpty)
        )
    }

    private static func cleanedNegativePrompt(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("-") { return value.drop(while: { $0 == "-" || $0.isWhitespace }).nilIfEmpty }
        return value.nilIfEmpty
    }

    private static func parseDrawThingsJSON(_ value: String) -> (prompt: String?, negativePrompt: String?, parameters: [PNGTextEntry])? {
        guard
            let data = value.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else { return nil }

        let prompt = stringValue(forKeys: ["c", "prompt"], in: dictionary)?.nilIfEmpty
        let negativePrompt = stringValue(forKeys: ["uc", "negative_prompt", "negativePrompt"], in: dictionary)?.nilIfEmpty

        var parameters: [PNGTextEntry] = []
        appendParameter(named: "Model",                    fromKeys: ["model"],                                                   in: dictionary, into: &parameters)
        appendParameter(named: "Seed",                     fromKeys: ["seed"],                                                    in: dictionary, into: &parameters)
        appendParameter(named: "Steps",                    fromKeys: ["steps"],                                                   in: dictionary, into: &parameters)
        appendParameter(named: "Sampler",                  fromKeys: ["sampler"],                                                 in: dictionary, into: &parameters)
        appendParameter(named: "Guidance Scale",           fromKeys: ["guidanceScale"],                                           in: dictionary, into: &parameters)
        appendParameter(named: "Strength",                 fromKeys: ["strength"],                                                in: dictionary, into: &parameters)
        appendParameter(named: "Clip Skip",                fromKeys: ["clip_skip", "clipSkip"],                                   in: dictionary, into: &parameters)
        appendParameter(named: "Aesthetic Score",          fromKeys: ["aesthetic_score", "aestheticScore"],                       in: dictionary, into: &parameters)
        appendParameter(named: "Upscaler",                 fromKeys: ["upscaler"],                                                in: dictionary, into: &parameters)
        appendParameter(named: "Negative Aesthetic Score", fromKeys: ["negative_aesthetic_score", "negativeAestheticScore"],      in: dictionary, into: &parameters)
        appendParameter(named: "Original Size",            fromKeys: ["original_size", "originalSize"],                          in: dictionary, into: &parameters)
        appendParameter(named: "Target Size",              fromKeys: ["target_size", "targetSize"],                               in: dictionary, into: &parameters)

        if let width = stringValue(forKeys: ["width"], in: dictionary)?.nilIfEmpty,
           let height = stringValue(forKeys: ["height"], in: dictionary)?.nilIfEmpty {
            parameters.append(PNGTextEntry(keyword: "Size", value: "\(width) x \(height)"))
        }

        return (prompt, negativePrompt, deduplicate(parameters))
    }

    private static func appendParameter(named label: String, fromKeys keys: [String], in dictionary: [String: Any], into parameters: inout [PNGTextEntry]) {
        if let value = stringValue(forKeys: keys, in: dictionary)?.nilIfEmpty {
            parameters.append(PNGTextEntry(keyword: label, value: humanizeParameterValue(value)))
        }
    }

    // MARK: - Folder metadata

    private static func readJSON(from fileURL: URL) -> ImageMetadata? {
        guard
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
            fileSize > 0, fileSize <= maximumMetadataFileSize,
            let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else { return nil }

        let prompt = stringValue(forKeys: ["prompt"], in: dictionary)?.nilIfEmpty
        let negativePrompt = stringValue(forKeys: ["negative_prompt", "negativePrompt"], in: dictionary)?.nilIfEmpty
        let generationParameters = parseEntries(
            from: dictionary["generation_parameters"] ?? dictionary["generationParameters"] ?? dictionary["parameters"],
            defaultKeywordTransform: humanizeKey
        )
        let textEntries = parseEntries(
            from: dictionary["text_entries"] ?? dictionary["textEntries"] ?? dictionary["metadata"] ?? dictionary["details"],
            defaultKeywordTransform: humanizeKey
        )

        let fallbackEntries = fallbackEntriesFromDictionary(dictionary)
        let metadata = ImageMetadata(
            prompt: prompt,
            negativePrompt: negativePrompt,
            promptStatusMessage: nil,
            generationParameters: deduplicate(generationParameters),
            textEntries: deduplicate(textEntries + fallbackEntries)
        )
        return metadata.hasVisibleContent ? metadata : nil
    }

    private static func readCFG(from fileURL: URL) -> ImageMetadata? {
        guard
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
            fileSize > 0, fileSize <= maximumMetadataFileSize,
            let content = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return nil }

        let generationKeys: Set<String> = [
            "model", "sampler", "scheduler", "seed", "steps",
            "cfg", "cfg scale", "size", "width", "height",
            "denoise", "clip skip", "vae", "checkpoint"
        ]

        var prompt: String?
        var negativePrompt: String?
        var generationParameters: [PNGTextEntry] = []
        var textEntries: [PNGTextEntry] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";"), !line.hasPrefix("//") else { continue }
            guard let sepIndex = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let rawKey = line[..<sepIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = line[line.index(after: sepIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawKey.isEmpty, !rawValue.isEmpty else { continue }

            let normalizedKey = rawKey.lowercased()
            switch normalizedKey {
            case "prompt":
                prompt = rawValue
            case "negative_prompt", "negative prompt", "negativeprompt":
                negativePrompt = rawValue
            default:
                let entry = PNGTextEntry(keyword: humanizeKey(rawKey), value: rawValue)
                if generationKeys.contains(normalizedKey) { generationParameters.append(entry) }
                else { textEntries.append(entry) }
            }
        }

        let metadata = ImageMetadata(
            prompt: prompt?.nilIfEmpty,
            negativePrompt: negativePrompt?.nilIfEmpty,
            promptStatusMessage: nil,
            generationParameters: deduplicate(generationParameters),
            textEntries: deduplicate(textEntries)
        )
        return metadata.hasVisibleContent ? metadata : nil
    }

    private static func parseEntries(from value: Any?, defaultKeywordTransform: (String) -> String) -> [PNGTextEntry] {
        switch value {
        case let array as [[String: Any]]:
            return array.compactMap { item in
                guard
                    let keyword = stringValue(forKeys: ["keyword", "key", "name", "label"], in: item)?.nilIfEmpty,
                    let entryValue = stringValue(forKeys: ["value"], in: item)?.nilIfEmpty
                else { return nil }
                return PNGTextEntry(keyword: keyword, value: entryValue)
            }
        case let dictionary as [String: Any]:
            return dictionary.compactMap { key, entryValue in
                guard let value = stringifyValue(entryValue)?.nilIfEmpty else { return nil }
                return PNGTextEntry(keyword: defaultKeywordTransform(key), value: value)
            }
            .sorted { $0.keyword.localizedCaseInsensitiveCompare($1.keyword) == .orderedAscending }
        default:
            return []
        }
    }

    private static func fallbackEntriesFromDictionary(_ dictionary: [String: Any]) -> [PNGTextEntry] {
        let ignoredKeys: Set<String> = [
            "prompt", "negative_prompt", "negativeprompt",
            "generation_parameters", "generationparameters", "parameters",
            "text_entries", "textentries", "metadata", "details"
        ]
        return dictionary.compactMap { key, value in
            let normalizedKey = key.replacingOccurrences(of: "_", with: "").lowercased()
            guard !ignoredKeys.contains(normalizedKey), let stringified = stringifyValue(value)?.nilIfEmpty else { return nil }
            return PNGTextEntry(keyword: humanizeKey(key), value: stringified)
        }
        .sorted { $0.keyword.localizedCaseInsensitiveCompare($1.keyword) == .orderedAscending }
    }

    // MARK: - ComfyUI node helpers

    private static let samplerScoreFields: Set<String> = [
        "seed", "noise_seed", "steps", "cfg", "sampler_name", "scheduler", "denoise"
    ]

    private static func primarySamplerNode(in nodes: [String: [String: Any]]) -> [String: Any]? {
        var best: [String: Any]? = nil
        var bestScore = 0
        for node in nodes.values {
            let nodeInputs = inputs(of: node)
            let score = samplerScoreFields.filter { key in
                guard let val = nodeInputs[key] else { return false }
                return !(val is [Any])
            }.count
            if score > bestScore {
                bestScore = score
                best = node
            }
        }
        return bestScore > 0 ? best : nil
    }

    private static func classType(of node: [String: Any]) -> String? { node["class_type"] as? String }
    private static func inputs(of node: [String: Any]) -> [String: Any] { node["inputs"] as? [String: Any] ?? [:] }

    private static func stringInput(named key: String, in node: [String: Any]) -> String? {
        stringify(inputs(of: node)[key])?.nilIfEmpty
    }

    private static func appendParameter(named label: String, input key: String, from node: [String: Any], into parameters: inout [PNGTextEntry]) {
        if let value = stringify(inputs(of: node)[key])?.nilIfEmpty {
            parameters.append(PNGTextEntry(keyword: label, value: humanizeParameterValue(value)))
        }
    }

    private static func nodeReferenceID(forInput key: String, in node: [String: Any]) -> String? {
        guard let ref = inputs(of: node)[key] as? [Any], let nodeID = ref.first else { return nil }
        return String(describing: nodeID)
    }

    private static func nodeReference(forInput key: String, in node: [String: Any], nodes: [String: [String: Any]]) -> [String: Any]? {
        guard let id = nodeReferenceID(forInput: key, in: node) else { return nil }
        return nodes[id]
    }

    private static func nodeText(forInput key: String, in node: [String: Any], nodes: [String: [String: Any]]) -> String? {
        guard
            let referencedNodeID = nodeReferenceID(forInput: key, in: node),
            let referencedNode = nodes[referencedNodeID]
        else { return nil }
        return resolveTextFromNode(referencedNode, nodeID: referencedNodeID, nodes: nodes, depth: 0)
    }

    private static func resolveTextFromNode(_ node: [String: Any], nodeID: String?, nodes: [String: [String: Any]], depth: Int) -> String? {
        guard depth < 8 else { return nil }
        if let nodeID, let previewText = previewText(forSourceNodeID: nodeID, in: nodes) { return previewText }
        if let text = stringInput(named: "text", in: node), !text.isEmpty { return text }
        if let resolved = resolveStringPart(forInput: "text", in: node, nodes: nodes, depth: depth) { return resolved }

        switch classType(of: node) {
        case "StringConcatenate", "String Concatenate", "JoinStrings", "ConcatStrings":
            let delim = stringInput(named: "delimiter", in: node) ?? widgetStringValue(forInput: "delimiter", in: node) ?? ""
            let a = resolveStringPart(forInput: "string_a", in: node, nodes: nodes, depth: depth)
            let b = resolveStringPart(forInput: "string_b", in: node, nodes: nodes, depth: depth)
            let parts = [a, b].compactMap { $0?.nilIfEmpty }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: delim)
        case "PreviewAny":
            return stringInput(named: "preview_text", in: node) ?? stringInput(named: "preview_markdown", in: node)
        default:
            return nil
        }
    }

    private static func resolveStringPart(forInput key: String, in node: [String: Any], nodes: [String: [String: Any]], depth: Int) -> String? {
        let nodeInputs = inputs(of: node)
        if let direct = nodeInputs[key] as? String { return direct }
        if let referencedNodeID = nodeReferenceID(forInput: key, in: node),
           let refNode = nodes[referencedNodeID] {
            return resolveTextFromNode(refNode, nodeID: referencedNodeID, nodes: nodes, depth: depth + 1)
        }
        return widgetStringValue(forInput: key, in: node)
    }

    private static func previewText(forSourceNodeID sourceNodeID: String, in nodes: [String: [String: Any]]) -> String? {
        for previewNode in nodes.values where classType(of: previewNode) == "PreviewAny" {
            guard nodeReferenceID(forInput: "source", in: previewNode) == sourceNodeID else { continue }
            let text = stringInput(named: "preview_text", in: previewNode) ?? stringInput(named: "preview_markdown", in: previewNode)
            if let text, !text.isEmpty { return text }
        }
        return nil
    }

    private static func widgetStringValue(forInput key: String, in node: [String: Any]) -> String? {
        guard let widgets = node["widgets_values"] as? [Any] else { return nil }
        let index: Int?
        switch classType(of: node) {
        case "StringConcatenate", "String Concatenate", "JoinStrings", "ConcatStrings":
            index = ["string_a": 0, "string_b": 1, "delimiter": 2][key]
        default:
            index = nil
        }
        guard let index, widgets.indices.contains(index) else { return nil }
        return stringify(widgets[index])?.nilIfEmpty
    }

    private static func latentImageSize(for samplerNode: [String: Any], nodes: [String: [String: Any]]) -> String? {
        guard let latentNode = nodeReference(forInput: "latent_image", in: samplerNode, nodes: nodes) else { return nil }
        if let width = stringInput(named: "width", in: latentNode), let height = stringInput(named: "height", in: latentNode) {
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
}

private extension StringProtocol {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed)
    }
}
