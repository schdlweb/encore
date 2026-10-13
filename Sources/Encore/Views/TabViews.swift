import SwiftUI

// MARK: Search

struct SearchView: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var sections: [SearchService.Section] = []
    @State private var addonResults: [(CatalogDef, [Meta])] = []
    @State private var searching = false
    @State private var searchingAddon = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                    TextField("Movies, shows, anime…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .medium))
                        .focused($focused)
                    if searching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .glass(cornerRadius: 16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.top, 100)

                ForEach(sections) { section in
                    resultRow(section.title, section.items)
                }
                ForEach(addonResults, id: \.0.key) { def, metas in
                    resultRow("\(def.name) · \(def.displayType)", metas)
                }

                if query.trimmingCharacters(in: .whitespaces).count >= 2, !searching {
                    VStack(spacing: 10) {
                        if sections.isEmpty && addonResults.isEmpty {
                            Text("No results for “\(query)”.").foregroundStyle(Theme.textSecondary)
                        }
                        if addonResults.isEmpty, !app.addonSearchCatalogs.isEmpty {
                            Button {
                                Task { await searchAddon(query) }
                            } label: {
                                HStack(spacing: 8) {
                                    if searchingAddon { ProgressView().controlSize(.small) }
                                    Text(searchingAddon ? "Searching your addon…" : "Also search your addon's catalogs")
                                }
                            }
                            .buttonStyle(PillButtonStyle())
                            .disabled(searchingAddon)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 40)
        }
        .onAppear { focused = true }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            addonResults = []
            guard q.count >= 2 else { sections = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searching = true
            let found = await SearchService.search(q)
            guard !Task.isCancelled else { return }
            sections = found
            searching = false
        }
    }

    private func resultRow(_ title: String, _ metas: [Meta]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(metas) { PosterCard(meta: $0) }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 12)
            }
        }
    }

    /// The addon's own search, on request: slower, but finds addon-only content.
    private func searchAddon(_ q: String) async {
        guard let client = app.client else { return }
        searchingAddon = true
        defer { searchingAddon = false }
        let catalogs = app.addonSearchCatalogs
        var found: [String: [Meta]] = [:]
        await withTaskGroup(of: (String, [Meta]).self) { group in
            for c in catalogs {
                group.addTask { (c.key, (try? await client.catalog(c, search: q)) ?? []) }
            }
            for await (key, metas) in group where !metas.isEmpty {
                found[key] = metas
                addonResults = catalogs.compactMap { c in found[c.key].map { (c, $0) } }
            }
        }
    }
}

// MARK: Library

struct LibraryView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                Text("Library")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 100)

                ScreenTimeSection()

                let continuing = app.watch.continueWatching
                if !continuing.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Continue Watching")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 22) {
                                ForEach(continuing) { ContinueCard(entry: $0) }
                            }
                            .padding(.horizontal, Theme.gutter)
                            .padding(.vertical, 12)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "My List")
                    if app.watch.favorites.isEmpty {
                        Text("Use the + button on a title to save it here.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, Theme.gutter)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth + 10), spacing: 22, alignment: .top)],
                                  alignment: .leading, spacing: 26) {
                            ForEach(app.watch.favorites) { SavedPoster(title: $0) }
                        }
                        .padding(.horizontal, Theme.gutter)
                        .padding(.vertical, 12)
                    }
                }

                let history = app.watch.watchHistory
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "History")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 18) {
                                ForEach(history.prefix(60)) { HistoryCard(item: $0) }
                            }
                            .padding(.horizontal, Theme.gutter)
                            .padding(.vertical, 12)
                        }
                    }
                }

                let dropped = app.watch.droppedTitles
                if !dropped.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Dropped")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 22) {
                                ForEach(dropped) { title in
                                    SavedPoster(title: title)
                                        .opacity(0.6)
                                        .contextMenu { DropButton(metaId: title.id) }
                                }
                            }
                            .padding(.horizontal, Theme.gutter)
                            .padding(.vertical, 12)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 40)
        }
    }
}

struct SavedPoster: View {
    let title: SavedTitle
    @Environment(AppState.self) private var app

    var body: some View {
        Button { app.open(title) } label: {
            VStack(alignment: .leading, spacing: 8) {
                RemoteImage(url: title.poster, maxPixel: 450)
                    .frame(width: Theme.posterWidth, height: Theme.posterHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .hoverLift()
                Text(title.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    .frame(width: Theme.posterWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Settings

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var draftURL = ""

    var body: some View {
        @Bindable var s = app.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.top, 100)

                card("Addon") {
                    Text("Paste your AIOStreams manifest URL. Any Stremio addon works.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    HStack {
                        TextField("https://…/manifest.json", text: $draftURL)
                            .textFieldStyle(.roundedBorder)
                        Button("Connect") {
                            app.settings.manifestURL = draftURL
                            Task { await app.connect() }
                        }
                        .disabled(draftURL.isEmpty || app.connection == .loading)
                    }
                    switch app.connection {
                    case .loading: ProgressView().controlSize(.small)
                    case .failed(let m): Label(m, systemImage: "xmark.octagon").foregroundStyle(.red).font(.system(size: 13))
                    case .loaded:
                        if let m = app.manifest {
                            AddonRow(manifest: m)
                        }
                    case .idle: EmptyView()
                    }
                }

                card("Audio") {
                    Picker("Output channels", selection: $s.audioChannels) {
                        ForEach(AudioChannels.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Passthrough to receiver (Dolby Digital, DD+, DTS, TrueHD)", isOn: $s.passthrough)
                    note("Sends the compressed bitstream over HDMI/optical for your receiver to decode. Lossless TrueHD and DTS-HD usually can't pass through on macOS. When they can't, they play as lossless multichannel PCM.")
                    Toggle("Exclusive audio device access", isOn: $s.exclusiveAudio)
                    note("Takes the output device exclusively (Core Audio hog mode). Can help passthrough and bit-perfect output, but other apps go silent while playing.")
                    Toggle("Normalize volume when downmixing", isOn: $s.normalizeDownmix)
                    Toggle("Prefer the original language (Japanese for anime, Korean for K-dramas…)", isOn: $s.preferOriginalAudio)
                    note("Looked up per title from Wikidata, falling back to the list below.")
                                        LabeledContent("Preferred audio languages") { TextField("", text: $s.preferredAudioLanguages, prompt: Text("e.g. jpn,eng (empty = file default)")).textFieldStyle(.roundedBorder) }
                }

                card("Subtitles") {
                    Toggle("Turn on subtitles automatically", isOn: $s.subtitlesOnByDefault)
                    LabeledContent("Preferred subtitle languages") { TextField("", text: $s.preferredSubtitleLanguages, prompt: Text("e.g. en,eng")).textFieldStyle(.roundedBorder) }
                    Picker("Size", selection: $s.subtitleSize) {
                        ForEach(SubtitleSize.allCases) { Text($0.label).tag($0) }
                    }
                }

                card("Video & Playback") {
                    Toggle("Hardware decoding (VideoToolbox)", isOn: $s.hardwareDecoding)
                    Toggle("Debanding (smooths gradients in low-bitrate encodes)", isOn: $s.deband)
                    Toggle("HDR output on HDR screens", isOn: $s.hdrOutput)
                    note("HDR10 and HLG videos (and the HDR layer of most Dolby Vision files) play in real HDR on a screen that supports it, such as a MacBook Pro's. Elsewhere they're converted to standard range.")
                    Toggle("Play next episode automatically", isOn: $s.autoplayNext)
                    Toggle("Skip intros and recaps automatically", isOn: $s.autoSkipIntros)
                    note("Otherwise a Skip button appears. Times come from the file's chapters, IntroDB, or AniSkip for anime.")
                    Toggle("Play in a separate window", isOn: $s.playerInWindow)
                    note("Like Infuse: a resizable window shaped to the video, so you can keep browsing. Off plays over the whole app.")
                    Picker("Stream buffer", selection: $s.streamBuffer) {
                        ForEach(StreamBuffer.allCases) { Text($0.label).tag($0) }
                    }
                    note("Disk downloads far ahead of where you are, so skipping forward is instant and a shaky connection won't interrupt playback. It uses more bandwidth and temporary disk space, which is freed when the video closes.")
                    Toggle("Thumbnails while scrubbing", isOn: $s.scrubPreviews)
                    note("Opens a second, silent connection to the stream to grab frames when you hover the timeline.")
                    Picker("Skip interval", selection: $s.skipInterval) {
                        ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    note("Changes apply the next time a video starts.")
                }

                card("Sync") {
                    Toggle("Sync with AIOStreams (Jellyfin profile)", isOn: $s.jellyfinSync)
                        .onChange(of: s.jellyfinSync) { app.jellyfin.refreshStatus() }
                    note("Shares watch progress with apps that use your AIOStreams as a Jellyfin server (Odin, Infuse, Swiftfin…), as one of its profiles. Whichever app played something last sets where you resume.")
                    if s.jellyfinSync { JellyfinSignIn() }
                    Divider().padding(.vertical, 4)
                    Toggle("Track on Simkl", isOn: $s.simklSync)
                        .onChange(of: s.simklSync) { app.simkl.refreshStatus() }
                    note("Scrobbles what you watch to your Simkl history. If your AIOStreams already sends history to Simkl and you sync with it above, leave this off so plays aren't counted twice.")
                    if s.simklSync { SimklSignIn() }
                }

                card("Updates") {
                    HStack {
                        Text("Encore \(app.updater.currentVersion)")
                        Spacer()
                        switch app.updater.state {
                        case .checking: ProgressView().controlSize(.small)
                        case .upToDate: Text("Up to date").foregroundStyle(Theme.textTertiary)
                        case .available(let r): Text("\(r.version) available").foregroundStyle(Theme.accent)
                        case .failed(let msg): Text(msg).foregroundStyle(Theme.textTertiary).lineLimit(2)
                        default: EmptyView()
                        }
                        Button("Check for Updates") { Task { await app.updater.check(userInitiated: true) } }
                    }
                    if let r = app.updater.availableRelease {
                        Button("Install \(r.version) & Relaunch") { Task { await app.updater.install(r) } }
                    }
                    Toggle("Check for updates automatically", isOn: $s.autoUpdateCheck)
                    note("New versions come from github.com/\(Updater.repo). Installing replaces Encore and reopens it; your settings and history stay.")
                }

                card("Home Screen") {
                    Toggle("Recommended for You", isOn: $s.showRecommendations)
                    if !app.watch.stats.notInterested.isEmpty {
                        Button("Show \(app.watch.stats.notInterested.count) hidden recommendation\(app.watch.stats.notInterested.count == 1 ? "" : "s") again") {
                            app.watch.clearNotInterested()
                            Task { await app.loadRecommendations(force: true) }
                        }
                    }
                    note("A row of titles picked from what you've watched (anime picks from AniList, others from Wikidata). Nothing leaves your Mac except the lookups.")
                    note("Drag to reorder, untick to hide. Every catalog in your addon is available here, with no library cap.")
                    List {
                        // By type+id: some addons reuse an id across types ("Netflix" movies and
                        // series), and rows keyed on the id alone toggled the wrong one.
                        ForEach(app.orderedCatalogs, id: \.key) { def in
                            let visible = !app.settings.hiddenCatalogs.contains(def.key)
                            // Only the checkbox is a button; the rest of the row is free for
                            // dragging (a row-wide button swallowed the drag).
                            HStack(spacing: 10) {
                                Button { app.setCatalog(def, visible: !visible) } label: {
                                    Image(systemName: visible ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 15))
                                        .foregroundStyle(visible ? Color.accentColor : Theme.textTertiary)
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(visible ? "Hide from Home" : "Show on Home")
                                Text(def.name).foregroundStyle(visible ? Theme.textPrimary : Theme.textTertiary)
                                Text(def.displayType).foregroundStyle(Theme.textTertiary).font(.system(size: 12))
                                Spacer()
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(Theme.textTertiary)
                                    .help("Drag to reorder")
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("Move to Top") { app.moveCatalog(def, toTop: true) }
                                Button("Move to Bottom") { app.moveCatalog(def, toTop: false) }
                            }
                        }
                        .onMove { app.moveCatalogs(from: $0, to: $1) }
                    }
                    .frame(height: 420)
                    .scrollContentBackground(.hidden)
                    HStack {
                        Button("Show All") { app.settings.hiddenCatalogs = []; app.rebuildRows() }
                        Button("Reset Order") { app.settings.catalogOrder = []; app.rebuildRows() }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 60)
        }
        .onAppear { draftURL = app.settings.manifestURL }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 17, weight: .bold))
            content()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 18, tint: .black.opacity(0.25))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Onboarding

struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var url = ""

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 132, height: 132)
                .shadow(color: Theme.accent.opacity(0.35), radius: 30)
            Text("Welcome to Encore").font(.system(size: 36, weight: .bold))
            Text("Paste your AIOStreams manifest URL to load your catalogs and streams.")
                .font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
            HStack {
                TextField("https://…/manifest.json", text: $url)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .glass(cornerRadius: 12)
                    .onSubmit(connect)
                Button("Connect", action: connect)
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(url.isEmpty || app.connection == .loading)
            }
            .frame(width: 620)
            switch app.connection {
            case .loading: ProgressView()
            case .failed(let m): Text(m).foregroundStyle(.red).font(.system(size: 13)).frame(width: 620)
            default: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() {
        guard !url.isEmpty else { return }
        app.settings.manifestURL = url
        Task { await app.connect() }
    }
}

/// The connected addon, Fusion-style: name, version and what it provides, with Configure
/// (the addon's own settings page) and Copy Link.
struct AddonRow: View {
    let manifest: Manifest
    @Environment(AppState.self) private var app

    private var configureURL: URL? {
        let raw = app.settings.manifestURL
        guard raw.hasSuffix("manifest.json") else { return nil }
        return URL(string: String(raw.dropLast("manifest.json".count)) + "configure")
    }

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: manifest.logo, contentMode: .fit, maxPixel: 120)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.name).font(.system(size: 14, weight: .semibold))
                Text(["v\(manifest.version ?? "?")", manifest.resources.map(\.name).joined(separator: ", "), "\(manifest.catalogs.count) catalogs"]
                        .filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            if let configureURL {
                Button("Configure") { NSWorkspace.shared.open(configureURL) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.settings.manifestURL, forType: .string)
            }
            if let configureURL { Button("Configure") { NSWorkspace.shared.open(configureURL) } }
            Button("Reload") { Task { await app.connect() } }
        }
    }
}

private struct JellyfinSignIn: View {
    @Environment(AppState.self) private var app
    @State private var password = ""

    var body: some View {
        @Bindable var s = app.settings
        VStack(alignment: .leading, spacing: 8) {
            switch app.jellyfin.status {
            case .signedIn(let name):
                HStack {
                    Label("Signed in as \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.rating)
                    Spacer()
                    Button("Sync Now") { Task { await app.pullSync() } }
                    Button("Sign Out") { app.jellyfin.signOut() }
                }
                .font(.system(size: 13))
            default:
                LabeledContent("Profile name") {
                    TextField("", text: $s.jellyfinProfile, prompt: Text("the profile you picked in the other app"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Password") {
                    SecureField("", text: $password, prompt: Text("your AIOStreams password (password/PIN if it has a PIN)"))
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Sign In") { Task { await app.jellyfin.signIn(password: password); password = "" } }
                        .disabled(s.jellyfinProfile.isEmpty || password.isEmpty || app.jellyfin.status == .signingIn)
                    if app.jellyfin.status == .signingIn { ProgressView().controlSize(.small) }
                    if case .failed(let msg) = app.jellyfin.status {
                        Text(msg).foregroundStyle(.red).font(.system(size: 12))
                    }
                }
                Text("The password is only used to sign in; Encore keeps just the sign-in token.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
        // First sync right after signing in.
        .onChange(of: app.jellyfin.status) { _, new in
            if case .signedIn = new { Task { await app.pullSync() } }
        }
    }
}

private struct SimklSignIn: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var s = app.settings
        VStack(alignment: .leading, spacing: 8) {
            switch app.simkl.status {
            case .signedIn:
                HStack {
                    Label("Signed in to Simkl", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.rating)
                    Spacer()
                    Button("Sign Out") { app.simkl.signOut() }
                }
                .font(.system(size: 13))
            case .waitingForCode(let code, let url):
                HStack(spacing: 10) {
                    Text("Enter").foregroundStyle(Theme.textSecondary)
                    Text(code).font(.system(size: 18, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    Text("at").foregroundStyle(Theme.textSecondary)
                    Link(url.host ?? url.absoluteString, destination: url)
                    ProgressView().controlSize(.small)
                }
            default:
                HStack {
                    Button("Sign In with Simkl") { app.simkl.signIn() }
                    if case .failed(let msg) = app.simkl.status {
                        Text(msg).foregroundStyle(.red).font(.system(size: 12))
                    }
                }
                Text("Opens simkl.com to approve Encore; tracking starts as soon as you do.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
        .onChange(of: app.simkl.status) { _, new in
            if new == .signedIn { Task { await app.pullSync() } }
        }
    }
}
