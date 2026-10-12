import Foundation

/// Folds apps a later seed added into an existing `taxonomy.json` (#312). Pure: the caller
/// decides whether to save.
///
/// The file stays yours. A merge only ever adds a bundle id: it never removes, renames or
/// edits an app, a task, a project or an alias, and it leaves an id alone when any app in the
/// file already claims it, wherever you put it.
public enum TaxonomyMerge {
    /// Adds each of `bundleIDs` the way `seed` lists it:
    /// 1. already listed by an app in `file`: left alone;
    /// 2. the seed's app key is an app in `file`: the id joins that app;
    /// 3. the seed's key is unused by any app or web app in `file`: the seed's app is appended,
    ///    carrying only this id;
    /// 4. otherwise (the key is a web app's, or the seed does not list the id): skipped.
    ///
    /// `added` lists the ids that changed the file, in the order they were handled.
    public static func apply(
        _ file: Taxonomy,
        seed: Taxonomy = .seed,
        bundleIDs: [String]
    ) -> (taxonomy: Taxonomy, added: [String]) {
        var merged = file
        var added: [String] = []
        for id in bundleIDs {
            guard merged.app(bundleID: id) == nil, let seedApp = seed.app(bundleID: id) else { continue }
            if let index = merged.apps.firstIndex(where: { $0.key == seedApp.key }) {
                merged.apps[index].bundleIds.append(id)
            } else if !merged.allAppKeys.contains(seedApp.key) {
                var entry = seedApp
                entry.bundleIds = [id]
                merged.apps.append(entry)
            } else {
                continue
            }
            added.append(id)
        }
        return (merged, added)
    }
}
