import SwiftUI
import WorklensCore

/// The one banner every Settings tab shows while the configuration is broken (#126).
///
/// Injected once, above the `TabView`, rather than pasted into each of the seven tabs — seven
/// copies of a warning is seven places for it to go stale. It exists because of a specific lie:
/// when a load fails the app falls back to `Config.defaults()`, and every tab then renders those
/// defaults in the user's own controls as if they were their values. So the banner says what is
/// wrong, which file it is in, and — while an error stands — that the tabs below are showing
/// built-in defaults rather than anything the user wrote.
///
/// Advisory warnings (an unknown key, a model id that is in no price table) get the quieter
/// treatment: same banner, no alarm, no claim that anything is being overridden.
struct ConfigBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let state = model.state
        let storage = state.storageError
        let error = state.configError
        let warnings = state.configWarnings
        if storage != nil || error != nil || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let storage {
                    Label(storage, systemImage: "externaldrive.trianglebadge.exclamationmark")
                        .font(Theme.Text.statusTitle)
                    Text(String(localized: "Nothing is being captured until Worklens has a folder it can write to.", comment: "Label"))
                        .font(Theme.Text.metadata)
                        .foregroundStyle(.secondary)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Text.statusTitle)
                    ForEach(state.configErrorDetails, id: \.self) { detail in
                        Text(detail)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text(
                        String(
                            localized:
                                "Until this is fixed the tabs below are showing Worklens's built-in defaults, not your values.",
                            comment: "Label")
                    )
                    .font(Theme.Text.metadata)
                    .foregroundStyle(.secondary)
                }
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(.secondary)
                }
                if let path = state.configErrorFile, error != nil {
                    Text(path)
                        .font(Theme.Text.metadata.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if storage != nil || error != nil {
                    HStack(spacing: 8) {
                        Button(String(localized: "Open file", comment: "Button")) { model.openEnvFile() }
                        Button(String(localized: "Reload", comment: "Button")) { model.reloadConfig() }
                        if error != nil {
                            Button(String(localized: "Use defaults for these keys", comment: "Button")) { model.startOnDefaults() }
                        }
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(bannerBackground(isError: storage != nil || error != nil))
        }
    }

    private func bannerBackground(isError: Bool) -> some View {
        Theme.Surface.shape
            .fill((isError ? Color.orange : Color.secondary).opacity(0.12))
    }
}
