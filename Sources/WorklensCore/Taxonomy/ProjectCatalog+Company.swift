import Foundation

/// The catalog's company-add seam (#317, shared with #318): what creates a `company` entry
/// without anyone confirming it (D2). Static, taking the store, because `ProjectCatalog` keeps
/// its store private to its own file.
extension ProjectCatalog {
    /// Adds a `company` entry named `name`, keyed on its folded name, answering to `aliases` too,
    /// and returns it. Idempotent: when an entry already answers to the name or to every alias,
    /// that entry comes back and nothing is written, unless it is the house entry, which is
    /// refused. An alias another entry owns is refused, so the saved catalog always validates.
    @discardableResult
    public static func addCompany(
        name: String, aliases: [String] = [], in taxonomy: TaxonomyStore
    ) throws -> ProjectEntry {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectCatalogError.emptyName }
        let key = ProjectEntry.fold(trimmed)
        var next = taxonomy.current
        let projects = next.projectList
        if let existing = projects.first(where: { $0.key == key || $0.matches(trimmed) }) {
            // The house entry is never a company: its spelling is taken, not answered.
            guard existing.kind != .house else { throw ProjectCatalogError.spellingTaken(trimmed, existing.key) }
            return existing
        }
        var extra: [String] = []
        for alias in aliases {
            let spelling = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spelling.isEmpty, ProjectEntry.fold(spelling) != key,
                  !extra.contains(where: { ProjectEntry.fold($0) == ProjectEntry.fold(spelling) })
            else { continue }
            if let owner = projects.first(where: { $0.matches(spelling) }) {
                throw ProjectCatalogError.spellingTaken(spelling, owner.key)
            }
            extra.append(spelling)
        }
        let entry = ProjectEntry(key: key, name: trimmed, aliases: extra.isEmpty ? nil : extra, kind: .company)
        next.projects = projects + [entry]
        try taxonomy.save(next)
        return entry
    }
}
