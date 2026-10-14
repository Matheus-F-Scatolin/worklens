import SwiftUI
import WorklensCore

/// Settings → Projects: the projects your time is grouped under, and "Learn from recent days".
///
/// It was Settings → Reports (#286) until the reports were cut (2026-10-05), then Settings → Log.
/// The Language picker moved to Capture, because it sets the language each summary is written in.
struct ProjectsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            ProjectsList(model: model)
                .settingsAnchor(.projects, model: model, cornerRadius: ReaderTheme.Radius.field)
        }
    }
}

// MARK: - Projects

/// The names your time is grouped under, and the other names each goes by (#286). One row
/// per project with a ••• menu: Rename…, Add an alias…, Merge into, Delete. Renaming and adding
/// an alias edit in place — Return saves, Esc leaves it as it was.
struct ProjectsList: View {
    @ObservedObject var model: AppModel
    @State private var projects: [ProjectEntry] = []
    @State private var editing: (key: String, isRename: Bool)?
    @State private var draft = ""
    @State private var problem: String?
    @State private var learning = false
    @State private var learned: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        SettingsGroup(
            String(localized: "Projects", comment: "Settings group"),
            note: String(localized: "Your timeline and stats group your time under these names. The aliases are the other names they go by.", comment: "Settings note")
        ) {
            if model.projectCatalog == nil {
                emptyLine(String(localized: "Worklens has not finished starting up.", comment: "Label"))
            } else if projects.isEmpty {
                emptyLine(String(localized: "No projects yet. A name seen on two separate days becomes one.", comment: "Label"))
            }
            ForEach(projects, id: \.key) { project in
                row(project)
            }
            HStack(spacing: 10) {
                Button(learning
                    ? L10n.format("Reading the last %@ days…", String(ProjectCatalog.learningWindow))
                    : String(localized: "Learn from recent days", comment: "Button")
                ) { learn() }
                    .buttonStyle(.settings)
                    .disabled(learning || model.projectCatalog == nil)
                Spacer(minLength: 0)
                if let learned { SettingsValueText(learned) }
            }
            .padding(.top, 12)
            if let problem {
                Text(problem)
                    .font(ReaderTheme.Size.rowDetail)
                    .foregroundStyle(ReaderTheme.warn)
                    .padding(.top, 6)
            }
        }
        .onAppear(perform: reload)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(ReaderTheme.Size.rowDetail)
            .foregroundStyle(ReaderTheme.muted)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { SettingsHairline() }
    }

    private func row(_ project: ProjectEntry) -> some View {
        let aliases = project.aliases ?? []
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                if let editing, editing.key == project.key, editing.isRename {
                    field(String(localized: "New name", comment: "Placeholder"), project)
                } else {
                    Text(project.name).font(ReaderTheme.Size.rowTitle)
                }
                if let editing, editing.key == project.key, !editing.isRename {
                    field(L10n.format("Another name for %@", project.name), project)
                } else {
                    Text(aliases.isEmpty
                        ? String(localized: "no aliases", comment: "Label")
                        : L10n.format("also %@", aliases.joined(separator: ", ")))
                        .font(ReaderTheme.Size.rowDetail)
                        .foregroundStyle(ReaderTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button(String(localized: "Rename…", comment: "Menu")) { begin(project, rename: true) }
                Button(String(localized: "Add an alias…", comment: "Menu")) { begin(project, rename: false) }
                if !aliases.isEmpty {
                    Menu(String(localized: "Remove an alias", comment: "Menu")) {
                        ForEach(aliases, id: \.self) { alias in
                            Button(alias) {
                                edit(L10n.format("Removed %@", alias)) { try $0.removeAlias(alias, from: project.key) }
                            }
                        }
                    }
                }
                if projects.count > 1 {
                    Menu(String(localized: "Merge into", comment: "Menu")) {
                        ForEach(projects.filter { $0.key != project.key }, id: \.key) { other in
                            Button(other.name) {
                                edit(L10n.format("Merged %@ into %@", project.name, other.name)) {
                                    try $0.merge(key: project.key, into: other.key)
                                }
                            }
                        }
                    }
                }
                Divider()
                Button(String(localized: "Delete", comment: "Menu"), role: .destructive) {
                    edit(L10n.format("Deleted %@", project.name)) { try $0.forget(key: project.key) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(ReaderTheme.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.format("More for %@", project.name))
        }
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { SettingsHairline() }
    }

    private func field(_ prompt: String, _ project: ProjectEntry) -> some View {
        TextField(prompt, text: $draft)
            .textFieldStyle(SettingsFieldStyle(width: 240))
            .focused($fieldFocused)
            .onSubmit { commit(project) }
            .onExitCommand { editing = nil }
            .onAppear { fieldFocused = true }
    }

    private func begin(_ project: ProjectEntry, rename: Bool) {
        draft = rename ? project.name : ""
        editing = (project.key, rename)
    }

    private func commit(_ project: ProjectEntry) {
        guard let editing else { return }
        let value = draft.trimmingCharacters(in: .whitespaces)
        self.editing = nil
        guard !value.isEmpty else { return }
        if editing.isRename {
            guard value != project.name else { return }
            edit(String(localized: "Project renamed", comment: "Toast")) { try $0.rename(key: project.key, to: value) }
        } else {
            edit(String(localized: "Alias added", comment: "Toast")) { try $0.addAlias(value, to: project.key) }
        }
    }

    private func reload() {
        projects = model.projectCatalog?.projects ?? []
    }

    private func edit(_ toast: String, _ change: (ProjectCatalog) throws -> Void) {
        guard let catalog = model.projectCatalog else { return }
        problem = nil
        do {
            try change(catalog)
            model.settingsToast(toast)
        } catch {
            problem = "\(error)"
        }
        reload()
    }

    private func learn() {
        guard let catalog = model.projectCatalog else { return }
        learning = true
        problem = nil
        Task {
            do {
                let change = try catalog.learn(upTo: DayBoundaries.dayString(Date()))
                let names = change.addedProjects.map(\.name)
                let spellings = change.addedAliases.values.reduce(0) { $0 + $1.count }
                if change.isEmpty {
                    learned = String(localized: "Nothing new since the last look.", comment: "Label")
                } else if names.isEmpty {
                    learned = L10n.plural(count: spellings, one: "Found %lld new alias", other: "Found %lld new aliases")
                } else {
                    learned = L10n.format("Found %@", ListFormatter.localizedString(byJoining: names))
                }
            } catch {
                problem = "\(error)"
            }
            learning = false
            reload()
        }
    }
}
