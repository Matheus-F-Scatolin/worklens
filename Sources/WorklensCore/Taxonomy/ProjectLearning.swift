import Foundation

/// Grows the canonical project list from what the days actually contained (#90).
///
/// There is no review loop and no model call: the describer names a project the way the screen
/// spelled it, `ProjectNames` says which of those spellings are one thing, and this decides what
/// that means for `taxonomy.json`.
///
/// Two rules, both conservative:
///
/// 1. **A cluster the list already claims gives up its other spellings as aliases.** Day one's
///    "Riverbend Capital Group" is in the list; day two's "Riverbend Capital" clusters with it, so it
///    becomes an alias and day three folds without needing the cluster at all.
/// 2. **A cluster the list does not claim becomes a project only once it has been seen on two
///    separate days.** One day's hint is as likely to be a page title the model latched onto as a
///    project; a thing you came back to the next day is a project. Its name is the most frequent
///    spelling, the rest become its aliases.
///
/// Nothing is ever removed and nothing is renamed — the list is the user's, and a wrong guess is
/// meant to be fixed by hand (`worklens projects rename|merge|alias`, or the Projects tab).
public enum ProjectLearning {
    /// How many separate days an unknown cluster has to appear on before it is a project.
    public static let daysToBecomeProject = 2

    /// The list as it should be after looking at `byDay`, or nil when nothing would change.
    ///
    /// `byDay` is a window of recent days (`ProjectCatalog` passes the last seven), each with the
    /// day's frame observations. Clustering runs over the whole window at once, so a spelling
    /// that only ever appears on its own still joins the project whose wording it contains.
    public static func learned(
        projects: [ProjectEntry], byDay: [String: [ProjectNames.Observation]]
    ) -> [ProjectEntry]? {
        /// folded label → original spelling → frames, and → the days it was seen on.
        var spellings: [String: [String: Int]] = [:]
        var days: [String: Set<String>] = [:]
        for (day, observations) in byDay {
            for observation in observations {
                // A frame the describer already gave a catalog key (#315) is that entry's, the
                // way `ProjectNames.resolve` counts it; its hint (often a codename on screen)
                // must not grow into a second project.
                if let key = observation.projectKey, ProjectEntry.lookup(key: key, in: projects) != nil {
                    continue
                }
                guard let label = ProjectNames.usableLabel(observation) else { continue }
                spellings[label.folded, default: [:]][label.cleaned, default: 0] += 1
                days[label.folded, default: []].insert(day)
            }
        }
        guard !spellings.isEmpty else { return nil }

        var clusters: [ProjectNames.Project: [String]] = [:]
        for (label, project) in ProjectNames.groups(spellings) {
            clusters[project, default: []].append(label)
        }

        var result = projects
        var changed = false
        // Sorted so two runs over the same window produce the same file.
        for (cluster, labels) in clusters.sorted(by: { $0.key.key < $1.key.key }) {
            let sorted = labels.sorted()
            let seen = Set(sorted.flatMap { days[$0] ?? [] })
            let candidates = sorted.flatMap { (spellings[$0] ?? [:]).keys.sorted() }

            if let owner = ProjectNames.claimant(of: sorted, spellings: spellings, in: result),
               let index = result.firstIndex(where: { $0.key == owner.key }) {
                let additions = candidates.filter { spelling in
                    !result.contains { $0.matches(spelling) }
                }
                guard !additions.isEmpty else { continue }
                result[index].aliases = (result[index].aliases ?? []) + additions
                changed = true
                continue
            }

            guard seen.count >= daysToBecomeProject else { continue }
            let key = ProjectEntry.fold(cluster.name)
            // A cluster whose name collides with a project that did not claim it (an alias
            // spelled differently, say) is left alone rather than made ambiguous.
            guard !key.isEmpty, !result.contains(where: { $0.key == key || $0.matches(cluster.name) })
            else { continue }
            let aliases = candidates.filter { spelling in
                spelling != cluster.name && !result.contains { $0.matches(spelling) }
            }
            result.append(ProjectEntry(
                key: key, name: cluster.name, aliases: aliases.isEmpty ? nil : aliases
            ))
            changed = true
        }
        return changed ? result : nil
    }
}
