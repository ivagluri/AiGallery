import Foundation

enum PromptDiffService {

    static func diff(a: ImageMetadata?, b: ImageMetadata?) -> MetadataDiff {
        MetadataDiff(
            promptTokens: diffTags(a?.prompt, b?.prompt),
            negativeTokens: diffTags(a?.negativePrompt, b?.negativePrompt),
            parameterDiffs: diffParameters(
                a?.generationParameters ?? [],
                b?.generationParameters ?? []
            )
        )
    }

    // Comma-split tags: A∩B = .unchanged, A\B = .removed, B\A = .added
    // Order: A's tags first (unchanged or removed), then B-only tags at end.
    private static func diffTags(_ a: String?, _ b: String?) -> [DiffToken] {
        let aTags = split(a)
        let bTags = split(b)
        guard !aTags.isEmpty || !bTags.isEmpty else { return [] }

        let bSet = Set(bTags)
        let aSet = Set(aTags)

        var tokens: [DiffToken] = aTags.map { tag in
            bSet.contains(tag) ? .unchanged(tag) : .removed(tag)
        }
        for tag in bTags where !aSet.contains(tag) {
            tokens.append(.added(tag))
        }
        return tokens
    }

    private static func split(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    // Union keywords; rows where at least one side has a value; changed rows first.
    private static func diffParameters(
        _ a: [PNGTextEntry], _ b: [PNGTextEntry]
    ) -> [(key: String, aValue: String?, bValue: String?)] {
        let aMap = Dictionary(a.map { ($0.keyword, $0.value) }, uniquingKeysWith: { first, _ in first })
        let bMap = Dictionary(b.map { ($0.keyword, $0.value) }, uniquingKeysWith: { first, _ in first })

        let allKeys = (Array(aMap.keys) + Array(bMap.keys))
            .reduce(into: [String]()) { acc, k in if !acc.contains(k) { acc.append(k) } }

        var changed: [(key: String, aValue: String?, bValue: String?)] = []
        var unchanged: [(key: String, aValue: String?, bValue: String?)] = []

        for key in allKeys {
            let av = aMap[key]
            let bv = bMap[key]
            guard av != nil || bv != nil else { continue }
            if av == bv {
                unchanged.append((key, av, bv))
            } else {
                changed.append((key, av, bv))
            }
        }
        return changed + unchanged
    }
}
