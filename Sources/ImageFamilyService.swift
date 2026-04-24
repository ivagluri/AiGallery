import Foundation

enum ImageFamilyService {

    static let minimumScore = 35
    static let maxResults = 20

    struct SourceContext {
        let item: ImageItem
        let prompt: String?
        let row: IndexedImageRow?
    }

    struct CandidateInput {
        let item: ImageItem
        let row: IndexedImageRow?
        let isSameFolder: Bool
    }

    // Returns nil if the candidate scores below minimumScore.
    static func evaluate(_ candidate: CandidateInput, source: SourceContext) -> ImageFamilyMatch? {
        guard candidate.item.id != source.item.id else { return nil }

        var score = 0
        var reasons: [ImageFamilyReason] = []

        // Folder proximity
        if candidate.isSameFolder {
            score += 15
            reasons.append(.sameFolder)
        }

        // Filename similarity
        if filenameRelated(candidate.item.displayName, source.item.displayName) {
            score += 15
            reasons.append(.filenamePattern)
        }

        // Model match
        if let sm = source.row?.model, let cm = candidate.row?.model,
           !sm.isEmpty, !cm.isEmpty, sm == cm {
            score += 20
            reasons.append(.sameModel)
        }

        // Seed match
        if let ss = source.row?.seed, let cs = candidate.row?.seed,
           !ss.isEmpty, !cs.isEmpty, ss == cs {
            score += 25
            reasons.append(.sameSeed)
        }

        // Prompt comparison
        if let sp = source.prompt, let cp = candidate.row?.prompt,
           !sp.isEmpty, !cp.isEmpty {
            if sp == cp {
                score += 40
                reasons.append(.samePrompt)
            } else if promptWordOverlap(sp, cp) > 0.5 {
                score += 20
                reasons.append(.similarPrompt)
            }
        }

        // Timestamp proximity (within 5 minutes)
        if let st = source.row?.modDate, let ct = candidate.row?.modDate,
           abs(st - ct) <= 300 {
            score += 10
            reasons.append(.closeTimestamp)
        }

        // Dimension relationship
        if let sw = source.row?.width, let sh = source.row?.height,
           let cw = candidate.row?.width, let ch = candidate.row?.height,
           sw > 0, sh > 0, cw > 0, ch > 0 {
            let sourceAspect = Double(sw) / Double(sh)
            let candidateAspect = Double(cw) / Double(ch)
            let deviation = abs(candidateAspect - sourceAspect) / sourceAspect

            if cw * ch > sw * sh && deviation < 0.02 {
                score += 10
                reasons.append(.upscaleDimensions)
            } else if deviation > 0.15 {
                score -= 20
            }
        }

        guard score >= minimumScore else { return nil }

        return ImageFamilyMatch(
            image: candidate.item,
            relationship: relationship(for: reasons),
            score: score,
            reasons: reasons
        )
    }

    static func relationship(for reasons: [ImageFamilyReason]) -> ImageRelationship {
        if reasons.contains(.upscaleDimensions) { return .upscale }
        if reasons.contains(.sameSeed)
            || (reasons.contains(.sameModel)
                && (reasons.contains(.samePrompt) || reasons.contains(.similarPrompt))) {
            return .variant
        }
        if reasons.contains(.sameFolder)
            && (reasons.contains(.filenamePattern) || reasons.contains(.closeTimestamp)) {
            return .sibling
        }
        return .related
    }

    // MARK: - Filename similarity

    private static func filenameRelated(_ a: String, _ b: String) -> Bool {
        guard a != b else { return false }

        let aLower = a.lowercased()
        let bLower = b.lowercased()

        // Shared prefix of >= 5 chars
        let commonLen = zip(aLower, bLower).prefix(while: { $0 == $1 }).count
        if commonLen >= 5 { return true }

        // Numeric-suffix siblings: strip trailing digits/separators and compare stems
        let stemPattern = #"\s*[\-_ ]?\d+$"#
        let stemA = a.replacingOccurrences(of: stemPattern, with: "", options: .regularExpression)
        let stemB = b.replacingOccurrences(of: stemPattern, with: "", options: .regularExpression)
        if stemA.count >= 3, stemA.lowercased() == stemB.lowercased(), stemA != a || stemB != b {
            return true
        }

        return false
    }

    // MARK: - Prompt similarity

    private static func promptWordOverlap(_ a: String, _ b: String) -> Double {
        let setA = Set(tokenize(a))
        let setB = Set(tokenize(b))
        guard !setA.isEmpty, !setB.isEmpty else { return 0 }
        let intersection = setA.intersection(setB).count
        return Double(intersection) / Double(min(setA.count, setB.count))
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }
}
