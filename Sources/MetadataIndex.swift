import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro not bridged to Swift — define it manually.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MetadataIndexError: Error {
    case cannotOpenDatabase(String)
    case schemaSetupFailed(String)
}

actor MetadataIndex {
    private var db: OpaquePointer?
    let dbURL: URL

    init(rootURL: URL) throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDir = appSupport.appendingPathComponent("AiGallery")
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        // Stable filename per root URL — djb2 hash of the standardised path
        var hash: UInt64 = 5381
        for byte in rootURL.standardizedFileURL.path.utf8 {
            hash = hash &* 31 &+ UInt64(byte)
        }
        self.dbURL = appDir.appendingPathComponent(String(format: "%016llx.sqlite", hash))

        var ptr: OpaquePointer?
        let rc = sqlite3_open(dbURL.path, &ptr)
        guard rc == SQLITE_OK, let opened = ptr else {
            let msg = ptr.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let p = ptr { sqlite3_close(p) }
            throw MetadataIndexError.cannotOpenDatabase(msg)
        }
        self.db = opened

        // WAL for better read concurrency; NORMAL sync is safe for a cache DB.
        sqlite3_exec(opened, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(opened, "PRAGMA synchronous=NORMAL;", nil, nil, nil)

        try createSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    func scan(images: [ImageItem], onProgress: @escaping @Sendable (Double) -> Void) async {
        guard let db else { return }
        let total = images.count
        guard total > 0 else { onProgress(1.0); return }

        // Load all currently-indexed paths + mod dates in one pass.
        var existing: [String: Double] = [:]
        existing.reserveCapacity(total)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT path, mod_date FROM indexed_images", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(stmt, 0))
                existing[path] = sqlite3_column_double(stmt, 1)
            }
        }
        sqlite3_finalize(stmt)

        // Remove rows whose files are no longer in the library.
        let livePaths = Set(images.map(\.id))
        let stale = Set(existing.keys).subtracting(livePaths)
        if !stale.isEmpty { removePaths(stale) }

        let upsertSQL = """
        INSERT OR REPLACE INTO indexed_images
        (path,mod_date,model,sampler,scheduler,vae,upscaler,steps,cfg,strength,width,height,source_fmt)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var upsert: OpaquePointer?
        guard sqlite3_prepare_v2(db, upsertSQL, -1, &upsert, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(upsert) }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var uncommitted = 0
        var done = 0

        for image in images {
            let modDate = Self.fileModDate(for: image.fileURL) ?? 0

            // Skip files whose mod date hasn't changed — already indexed correctly.
            if existing[image.id] == modDate {
                done += 1
                if done % 500 == 0 { onProgress(Double(done) / Double(total)) }
                continue
            }

            let row = Self.extractRow(for: image, modDate: modDate)
            Self.bind(row, path: image.id, to: upsert!)
            if sqlite3_step(upsert) != SQLITE_DONE { /* best-effort */ }
            sqlite3_reset(upsert)
            sqlite3_clear_bindings(upsert)

            uncommitted += 1
            done += 1

            if uncommitted >= 200 {
                sqlite3_exec(db, "COMMIT", nil, nil, nil)
                sqlite3_exec(db, "BEGIN", nil, nil, nil)
                uncommitted = 0
            }
            if done % 100 == 0 {
                onProgress(Double(done) / Double(total))
                await Task.yield()
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        onProgress(1.0)
    }

    func facetValues(for field: MetadataField) -> [(value: String, count: Int)] {
        guard let db else { return [] }
        let col = field.columnName
        let sql = """
        SELECT \(col), COUNT(*) AS n FROM indexed_images
        WHERE \(col) IS NOT NULL
        GROUP BY \(col) ORDER BY n DESC
        """
        var stmt: OpaquePointer?
        var results: [(String, Int)] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let value = String(cString: sqlite3_column_text(stmt, 0))
                let count = Int(sqlite3_column_int(stmt, 1))
                results.append((value, count))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    func imagePaths(matching filters: [MetadataFilter]) -> Set<String> {
        guard let db, !filters.isEmpty else { return [] }
        let clauses = filters.map { "\($0.field.columnName) = ?" }.joined(separator: " AND ")
        let sql = "SELECT path FROM indexed_images WHERE \(clauses)"
        var stmt: OpaquePointer?
        var paths = Set<String>()
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (i, filter) in filters.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), filter.value, -1, SQLITE_TRANSIENT)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                paths.insert(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        sqlite3_finalize(stmt)
        return paths
    }

    func imagePaths(where field: MetadataField, contains query: String) -> Set<String> {
        guard let db else { return [] }
        let col = field.columnName
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%",  with: "\\%")
            .replacingOccurrences(of: "_",  with: "\\_")
        let pattern = "%\(escaped)%"
        let sql = "SELECT path FROM indexed_images WHERE \(col) LIKE ? ESCAPE '\\'"
        var stmt: OpaquePointer?
        var paths = Set<String>()
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                paths.insert(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        sqlite3_finalize(stmt)
        return paths
    }

    // MARK: - Private

    private func createSchema() throws {
        let ddl = """
        CREATE TABLE IF NOT EXISTS indexed_images (
            path       TEXT    PRIMARY KEY,
            mod_date   REAL    NOT NULL,
            model      TEXT,
            sampler    TEXT,
            scheduler  TEXT,
            vae        TEXT,
            upscaler   TEXT,
            steps      INTEGER,
            cfg        REAL,
            strength   REAL,
            width      INTEGER,
            height     INTEGER,
            source_fmt TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_model     ON indexed_images(model);
        CREATE INDEX IF NOT EXISTS idx_sampler   ON indexed_images(sampler);
        CREATE INDEX IF NOT EXISTS idx_scheduler ON indexed_images(scheduler);
        CREATE INDEX IF NOT EXISTS idx_vae       ON indexed_images(vae);
        """
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, ddl, nil, nil, &errmsg) == SQLITE_OK else {
            let msg = errmsg.map { String(cString: $0) } ?? "schema error"
            sqlite3_free(errmsg)
            throw MetadataIndexError.schemaSetupFailed(msg)
        }
    }

    private func removePaths(_ paths: Set<String>) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM indexed_images WHERE path = ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for path in paths {
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
    }

    // MARK: - Row extraction (static: called off-actor during scan)

    private struct IndexRow {
        var modDate: Double
        var model: String?
        var sampler: String?
        var scheduler: String?
        var vae: String?
        var upscaler: String?
        var steps: Int?
        var cfg: Double?
        var strength: Double?
        var width: Int?
        var height: Int?
        var sourceFmt: String?
    }

    private static func extractRow(for image: ImageItem, modDate: Double) -> IndexRow {
        let isPNG = image.fileURL.pathExtension.lowercased() == "png"
        let pngMeta: ImageMetadata? = isPNG ? PNGInfoReader.read(from: image.fileURL) : nil
        // Only fall back to folder metadata if PNG parse found nothing.
        let folderMeta: ImageMetadata? = pngMeta == nil
            ? FolderMetadataReader.read(from: image.fileURL.deletingLastPathComponent())
            : nil

        let params = pngMeta?.generationParameters ?? folderMeta?.generationParameters ?? []
        guard !params.isEmpty else {
            return IndexRow(modDate: modDate)
        }

        let fmt = detectSourceFormat(params: params)

        let rawModel    = param("Model",           in: params)
        let rawSampler  = param("Sampler",         in: params)
        let rawScheduler = param("Scheduler",      in: params)
        let rawVAE      = param("VAE",             in: params)
        let rawUpscaler = param("Hires upscaler",  in: params)
                       ?? param("Upscale Method",  in: params)

        let model = rawModel.flatMap { normalizeModelName($0) }

        let (sampler, derivedScheduler) = rawSampler
            .map { splitA1111Sampler($0, fmt: fmt) } ?? (nil, nil)

        // ComfyUI provides Scheduler directly; for A1111 we derive it from the sampler string.
        let scheduler = (rawScheduler ?? derivedScheduler)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let vae = rawVAE
            .flatMap { normalizeModelName($0) ?? ($0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let upscaler = rawUpscaler
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let steps = param("Steps", in: params).flatMap { Int($0) }
        let cfg   = param("CFG scale",     in: params).flatMap { Double($0) }
                 ?? param("CFG Scale",     in: params).flatMap { Double($0) }
                 ?? param("Guidance Scale",in: params).flatMap { Double($0) }
        let strength = param("Denoising strength", in: params).flatMap { Double($0) }
                    ?? param("Denoise",             in: params).flatMap { Double($0) }
                    ?? param("Strength",            in: params).flatMap { Double($0) }

        var width: Int?
        var height: Int?
        if let sizeStr = param("Size", in: params) {
            let parts = sizeStr.split(separator: "x")
            if parts.count == 2 { width = Int(parts[0]); height = Int(parts[1]) }
        }

        return IndexRow(
            modDate: modDate, model: model, sampler: sampler, scheduler: scheduler,
            vae: vae, upscaler: upscaler, steps: steps, cfg: cfg, strength: strength,
            width: width, height: height, sourceFmt: fmt
        )
    }

    private static func param(_ keyword: String, in params: [PNGTextEntry]) -> String? {
        let v = params.first {
            $0.keyword.compare(keyword, options: .caseInsensitive) == .orderedSame
        }?.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func detectSourceFormat(params: [PNGTextEntry]) -> String? {
        // ComfyUI is the only format with a distinct "Scheduler" key.
        if params.contains(where: { $0.keyword.compare("Scheduler", options: .caseInsensitive) == .orderedSame }) {
            return "comfyui"
        }
        // DrawThings uses "Guidance Scale" rather than "CFG scale".
        if params.contains(where: { $0.keyword.compare("Guidance Scale", options: .caseInsensitive) == .orderedSame }) {
            return "drawthings"
        }
        return params.isEmpty ? nil : "a1111"
    }

    private static func normalizeModelName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Strip any directory path and file extension.
        var name = URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent

        // Strip hash annotations: " [31e35c80fc]" or "(31e35c80fc)".
        if let range = name.range(of: #"\s*[\[\(][0-9a-fA-F]{6,}[\]\)]$"#, options: .regularExpression) {
            name = String(name[..<range.lowerBound])
        }

        // Strip common precision/pruning suffixes.
        for suffix in ["-pruned", "-emaonly", "-fp16", "-fp8", "-bf16",
                       "_pruned", "_emaonly", "_fp16", "_fp8", "_bf16"] {
            if name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }

        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // Splits A1111's combined "DPM++ 2M Karras" → sampler "DPM++ 2M", scheduler "karras".
    // ComfyUI already provides them separately, so no splitting is needed there.
    private static func splitA1111Sampler(_ raw: String, fmt: String?) -> (sampler: String?, scheduler: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }
        guard fmt != "comfyui" else { return (trimmed, nil) }

        for suffix in ["Karras", "Exponential", "SGM Uniform", "Simple", "Beta"] {
            if trimmed.lowercased().hasSuffix(suffix.lowercased()) {
                let base = String(trimmed.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (base.isEmpty ? trimmed : base, suffix.lowercased())
            }
        }
        return (trimmed, nil)
    }

    private static func fileModDate(for url: URL) -> Double? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate)
            .map(\.timeIntervalSinceReferenceDate)
    }

    // MARK: - Bind helpers

    private static func bind(_ row: IndexRow, path: String, to stmt: OpaquePointer) {
        sqlite3_bind_text  (stmt,  1, path,          -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt,  2, row.modDate)
        bindText           (stmt,  3, row.model)
        bindText           (stmt,  4, row.sampler)
        bindText           (stmt,  5, row.scheduler)
        bindText           (stmt,  6, row.vae)
        bindText           (stmt,  7, row.upscaler)
        bindInt            (stmt,  8, row.steps)
        bindDouble         (stmt,  9, row.cfg)
        bindDouble         (stmt, 10, row.strength)
        bindInt            (stmt, 11, row.width)
        bindInt            (stmt, 12, row.height)
        bindText           (stmt, 13, row.sourceFmt)
    }

    private static func bindText(_ s: OpaquePointer, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(s, i, v, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(s, i) }
    }

    private static func bindInt(_ s: OpaquePointer, _ i: Int32, _ v: Int?) {
        if let v { sqlite3_bind_int64(s, i, Int64(v)) }
        else { sqlite3_bind_null(s, i) }
    }

    private static func bindDouble(_ s: OpaquePointer, _ i: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(s, i, v) }
        else { sqlite3_bind_null(s, i) }
    }
}
