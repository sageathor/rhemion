// Dictionary — the personal word-replacement dictionary, owned by the app. There is no note and no
// compiler: the app reads and writes the SAME snapshot the runtime applies:
// $RHEMION_RUNTIME_DIR/active/dictionary.json (default: ~/.local/state/rhemion-v3/active/dictionary.json).
//
// Compiled v1 shape (unchanged, so the runtime's RecognitionDictionary reads it as-is):
//   {"version":1,"replacements":[["variant","Canonical"], ...],"bias":["Term", ...]}
// A replacement is applied variant -> canonical (whole-word, case-insensitive, leftmost-longest) by the
// runtime. Here each ENTRY groups all variants that map to one canonical (like
// `Canonical = variant1, variant2`), so the same result is a single row; the file still stores flat
// [variant, canonical] pairs. `bias` is parsed but not applied by the app; carried through untouched.

import Foundation

/// One grouped replacement: any of the comma-separated `variants` (what you say) becomes `canonical`
/// (what it turns into). Identifiable for SwiftUI list editing.
struct ReplacementEntry: Identifiable, Equatable {
    let id: UUID
    var variants: String     // comma-separated spoken variants
    var canonical: String    // the replacement they all become

    init(id: UUID = UUID(), variants: String = "", canonical: String = "") {
        self.id = id; self.variants = variants; self.canonical = canonical
    }
}

struct DictionaryDoc: Equatable {
    var entries: [ReplacementEntry] = []
    var bias: [String] = []          // carried through unchanged (not applied, no UI yet)
}

/// Reads and writes active/dictionary.json. Never throws on read (missing/malformed → empty). Writes
/// atomically, owner-only. Mirrors SettingsStore.
enum DictionaryStore {
    static var url: URL { AppPaths.stateDir.appendingPathComponent("active/dictionary.json", isDirectory: false) }

    static func load() -> DictionaryDoc {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return DictionaryDoc() }
        let rows = (object["replacements"] as? [[String]]) ?? []
        // Group flat [variant, canonical] pairs by canonical, preserving first-seen order, so the same
        // result shows as one row with its variants joined.
        var order: [String] = []
        var variantsByCanonical: [String: [String]] = [:]
        for row in rows where row.count == 2 && !row[0].isEmpty && !row[1].isEmpty {
            let variant = row[0], canonical = row[1]
            if variantsByCanonical[canonical] == nil { order.append(canonical) }
            variantsByCanonical[canonical, default: []].append(variant)
        }
        let entries = order.map {
            ReplacementEntry(variants: (variantsByCanonical[$0] ?? []).joined(separator: ", "), canonical: $0)
        }
        let bias = (object["bias"] as? [String]) ?? []
        return DictionaryDoc(entries: entries, bias: bias)
    }

    /// Write the v1 snapshot. Each entry expands to one [variant, canonical] pair per comma-separated
    /// variant; empty variants/canonicals are dropped (the runtime would skip them anyway). A given
    /// spoken variant is written at most once across ALL rows — first occurrence wins, compared
    /// case-insensitively (the runtime matches case-insensitively, so two variants differing only in
    /// case are the same match), so the file can't hold the same variant pointing at two canonicals.
    /// `bias` is preserved.
    /// Up while a storage operation holds the barrier (DataOperations.quiesce → resume). A real Reset /
    /// Uninstall never resumes, so it also covers the settings-write-suppressed tail: an open Dictionary
    /// window's edit can't resurrect a dictionary.json that is being (or was just) deleted.
    static let writesSuppressed = Locked(false)

    @discardableResult
    static func save(_ doc: DictionaryDoc) -> Bool {
        guard !writesSuppressed.value else {
            log("dictionary: save skipped — a storage operation is in progress")
            return false
        }
        var replacements: [[String]] = []
        var seen = Set<String>()
        for entry in doc.entries {
            let canonical = entry.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { continue }
            for piece in entry.variants.split(separator: ",") {
                let variant = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !variant.isEmpty, seen.insert(variant.lowercased()).inserted else { continue }
                replacements.append([variant, canonical])
            }
        }
        var object: [String: Any] = ["version": 1, "replacements": replacements]
        if !doc.bias.isEmpty { object["bias"] = doc.bias }

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            // .atomic renames onto url in one step: the runtime's DictionaryStore (which hot-reloads by
            // mtime) never sees a missing or half-written file, and a failed write keeps the prior one.
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    enum AddOutcome { case added, alreadyPresent, failed }

    /// Quick-add one replacement (dict-add hotkey). If the spoken variant already maps anywhere
    /// (case-insensitive, matching how the runtime and save() treat variants), it is `.alreadyPresent`;
    /// otherwise the variant is merged into an existing row whose canonical matches EXACTLY (a canonical
    /// differing only in case is a different replacement, so it is not merged), or a new row is inserted
    /// at the top. `.failed` if the write did not persist.
    @discardableResult
    static func add(variant: String, canonical: String) -> AddOutcome {
        let v = variant.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty, !c.isEmpty else { return .failed }
        var doc = load()
        let exists = doc.entries.contains { entry in
            entry.variants.split(separator: ",").contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == v.lowercased()
            }
        }
        if exists { return .alreadyPresent }
        if let index = doc.entries.firstIndex(where: {
            $0.canonical.trimmingCharacters(in: .whitespacesAndNewlines) == c
        }) {
            let current = doc.entries[index].variants.trimmingCharacters(in: .whitespacesAndNewlines)
            doc.entries[index].variants = current.isEmpty ? v : current + ", " + v
        } else {
            doc.entries.insert(ReplacementEntry(variants: v, canonical: c), at: 0)
        }
        return save(doc) ? .added : .failed
    }
}
