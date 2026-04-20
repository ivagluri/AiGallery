import Foundation

enum FolderMetadataReader {
    private static let maximumMetadataFileSize = 1 * 1_024 * 1_024
    private static let supportedFileNames = [
        "aigallery.json",
        "aigallery.cfg",
        "metadata.json",
        "metadata.cfg"
    ]

    static func read(from folderURL: URL) -> FolderMetadata? {
        let fileManager = FileManager.default

        for fileName in supportedFileNames {
            let fileURL = folderURL.appendingPathComponent(fileName, isDirectory: false)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                continue
            }

            switch fileURL.pathExtension.lowercased() {
            case "json":
                if let metadata = readJSON(from: fileURL) {
                    return metadata
                }
            case "cfg":
                if let metadata = readCFG(from: fileURL) {
                    return metadata
                }
            default:
                break
            }
        }

        return nil
    }

    private static func readJSON(from fileURL: URL) -> FolderMetadata? {
        guard
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
            fileSize > 0,
            fileSize <= maximumMetadataFileSize,
            let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }

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
        let mergedTextEntries = deduplicate(textEntries + fallbackEntries)
        let metadata = FolderMetadata(
            prompt: prompt,
            negativePrompt: negativePrompt,
            generationParameters: deduplicate(generationParameters),
            textEntries: mergedTextEntries
        )

        return metadata.hasVisibleContent ? metadata : nil
    }

    private static func readCFG(from fileURL: URL) -> FolderMetadata? {
        guard
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
            fileSize > 0,
            fileSize <= maximumMetadataFileSize,
            let content = try? String(contentsOf: fileURL, encoding: .utf8)
        else {
            return nil
        }

        var prompt: String?
        var negativePrompt: String?
        var generationParameters: [PNGTextEntry] = []
        var textEntries: [PNGTextEntry] = []

        let generationKeys: Set<String> = [
            "model",
            "sampler",
            "scheduler",
            "seed",
            "steps",
            "cfg",
            "cfg scale",
            "size",
            "width",
            "height",
            "denoise",
            "clip skip",
            "vae",
            "checkpoint"
        ]

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";"), !line.hasPrefix("//") else {
                continue
            }

            guard
                let separatorIndex = line.firstIndex(where: { $0 == "=" || $0 == ":" })
            else {
                continue
            }

            let rawKey = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)

            guard !rawKey.isEmpty, !rawValue.isEmpty else {
                continue
            }

            let normalizedKey = rawKey.lowercased()
            switch normalizedKey {
            case "prompt":
                prompt = rawValue
            case "negative_prompt", "negative prompt", "negativeprompt":
                negativePrompt = rawValue
            default:
                let entry = PNGTextEntry(keyword: humanizeKey(rawKey), value: rawValue)
                if generationKeys.contains(normalizedKey) {
                    generationParameters.append(entry)
                } else {
                    textEntries.append(entry)
                }
            }
        }

        let metadata = FolderMetadata(
            prompt: prompt?.nilIfEmpty,
            negativePrompt: negativePrompt?.nilIfEmpty,
            generationParameters: deduplicate(generationParameters),
            textEntries: deduplicate(textEntries)
        )

        return metadata.hasVisibleContent ? metadata : nil
    }

    private static func parseEntries(
        from value: Any?,
        defaultKeywordTransform: (String) -> String
    ) -> [PNGTextEntry] {
        switch value {
        case let array as [[String: Any]]:
            return array.compactMap { item in
                guard
                    let keyword = stringValue(forKeys: ["keyword", "key", "name", "label"], in: item)?.nilIfEmpty,
                    let entryValue = stringValue(forKeys: ["value"], in: item)?.nilIfEmpty
                else {
                    return nil
                }

                return PNGTextEntry(keyword: keyword, value: entryValue)
            }
        case let dictionary as [String: Any]:
            return dictionary.compactMap { key, entryValue in
                guard let value = stringify(entryValue)?.nilIfEmpty else {
                    return nil
                }

                return PNGTextEntry(keyword: defaultKeywordTransform(key), value: value)
            }
            .sorted { $0.keyword.localizedCaseInsensitiveCompare($1.keyword) == .orderedAscending }
        default:
            return []
        }
    }

    private static func fallbackEntriesFromDictionary(_ dictionary: [String: Any]) -> [PNGTextEntry] {
        let ignoredKeys: Set<String> = [
            "prompt",
            "negative_prompt",
            "negativeprompt",
            "generation_parameters",
            "generationparameters",
            "parameters",
            "text_entries",
            "textentries",
            "metadata",
            "details"
        ]

        return dictionary.compactMap { key, value in
            let normalizedKey = key.replacingOccurrences(of: "_", with: "").lowercased()
            guard !ignoredKeys.contains(normalizedKey), let stringified = stringify(value)?.nilIfEmpty else {
                return nil
            }

            return PNGTextEntry(keyword: humanizeKey(key), value: stringified)
        }
        .sorted { $0.keyword.localizedCaseInsensitiveCompare($1.keyword) == .orderedAscending }
    }

    private static func stringValue(forKeys keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let value = dictionary[key], let stringified = stringify(value) {
                return stringified
            }
        }

        return nil
    }

    private static func stringify(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
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
        case let array as [Any]:
            let parts = array.compactMap(stringify)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default:
            return nil
        }
    }

    private static func humanizeKey(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in
                let lowercased = part.lowercased()
                switch lowercased {
                case "cfg":
                    return "CFG"
                case "vae":
                    return "VAE"
                default:
                    return lowercased.capitalized
                }
            }
            .joined(separator: " ")
    }

    private static func deduplicate(_ entries: [PNGTextEntry]) -> [PNGTextEntry] {
        var seen = Set<String>()
        var deduped: [PNGTextEntry] = []

        for entry in entries {
            let dedupeKey = "\(entry.keyword.lowercased())\u{1F}\(entry.value)"
            if seen.insert(dedupeKey).inserted {
                deduped.append(entry)
            }
        }

        return deduped
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
