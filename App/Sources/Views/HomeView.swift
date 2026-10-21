import SwiftUI

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var face: UIImage?
    @State private var showBlocked = false
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    if let notice = model.session.lastExitNotice {
                        Card {
                            Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        }
                    }
                    if let profile = model.selectedProfile {
                        playCard(profile)
                    } else {
                        Card {
                            Text("Create a profile in Installations to get started.").foregroundStyle(Theme.textSecondary)
                        }
                    }
                    recentProfiles
                    news
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("ZMF Java")
            .task(id: model.accounts.active?.id) { await loadFace() }
            .sheet(isPresented: $showBlocked) { blockedSheet }
            .sheet(isPresented: $showSignIn) { SignInView() }
            .onChange(of: model.session.state) { _, state in
                if case .blocked = state { showBlocked = true }
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 14) {
            Group {
                if let face {
                    Image(uiImage: face).interpolation(.none).resizable()
                } else {
                    Image(systemName: "person.crop.square.fill").resizable().foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                if let account = model.accounts.active {
                    Text(account.username).font(.title2.bold())
                    StatusBadge(text: account.ownsJavaEdition ? "Java Edition licensed" : "No license", color: account.ownsJavaEdition ? Theme.accent : Theme.danger,
                                symbol: "checkmark.shield")
                } else {
                    Text("Not signed in").font(.title2.bold())
                    Button { showSignIn = true } label: { Label("Sign in", systemImage: "person.badge.key") }
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
        .padding(18)
        .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func playCard(_ profile: GameProfile) -> some View {
        let status = model.compatibility(for: profile.launchVersionID)
        let installed = model.installer.isInstalled(profile.launchVersionID)
        let job = model.installer.tasks[profile.launchVersionID]
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).font(.headline)
                        Text("\(profile.loader.title) · Minecraft \(profile.minecraftVersion)").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    StatusBadge(text: installed ? "Installed" : "Not installed", color: installed ? Theme.accent : Theme.textSecondary)
                }
                StatusBadge(text: status.label, color: status.color, symbol: status.symbol)
                if let job {
                    ProgressView(value: job.progress) { Text(job.phase).font(.caption) } currentValueLabel: { Text(job.detail).font(.caption2) }
                }
                sessionStatus
                Button {
                    Task { await model.session.play(profile: profile, model: model) }
                } label: {
                    Label(installed ? "Play" : "Install & Play", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.accounts.active == nil || job != nil || isPreparing)
                if model.accounts.active == nil {
                    Text("A Microsoft account that owns Minecraft: Java Edition is required to play.").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var isPreparing: Bool {
        if case .preparing = model.session.state { return true }
        return false
    }

    @ViewBuilder private var sessionStatus: some View {
        switch model.session.state {
        case .preparing(let message):
            HStack { ProgressView(); Text(message).font(.subheadline) }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(Theme.danger)
        default:
            EmptyView()
        }
    }

    private var recentProfiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent profiles").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.profiles.recent) { p in
                        Button {
                            model.settingsStore.settings.selectedProfileID = p.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name).font(.subheadline.bold()).lineLimit(1)
                                Text("\(p.loader.title) \(p.minecraftVersion)").font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(12)
                            .frame(width: 150, alignment: .leading)
                            .background(p.id == model.selectedProfile?.id ? Theme.accentDeep.opacity(0.5) : Theme.surface,
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var news: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Launcher news").font(.headline)
            ForEach(model.news) { item in
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.subheadline.bold())
                        Text(item.body).font(.footnote).foregroundStyle(Theme.textSecondary)
                        if let d = item.date { Text(d, style: .date).font(.caption2).foregroundStyle(Theme.textSecondary) }
                    }
                }
            }
        }
    }

    private var blockedSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("ZMF will not show placeholder frames. The game starts only when every real component is present.")
                        .font(.footnote)
                }
                if case .blocked(let reasons) = model.session.state {
                    Section("What is missing") {
                        ForEach(reasons, id: \.self) { Label($0, systemImage: "shippingbox").font(.subheadline) }
                    }
                }
                Section {
                    Text("See docs/RUNTIME.md in the repository for how to embed an iOS Java runtime, LWJGL natives and a GL translation layer in the IPA build.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            .navigationTitle("Can't start yet")
            .toolbar { Button("OK") { showBlocked = false; model.session.state = .idle } }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadFace() async {
        guard let account = model.accounts.active, let skin = await SkinCache.skin(for: account) else { face = nil; return }
        face = SkinCache.face(from: skin, size: 112)
    }
}
