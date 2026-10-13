import SwiftUI

/// An actor's (or director's) page: photo, a line about them, and their other work.
struct PersonView: View {
    let member: CastMember
    var context: String? = nil
    @Environment(AppState.self) private var app
    @State private var person: DiscoveryService.Person?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .center, spacing: 28) {
                    Button { app.back() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 40, height: 40)
                            .glass()
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .frame(maxHeight: .infinity, alignment: .top)

                    ZStack {
                        Circle().fill(Color.white.opacity(0.08))
                        if member.photo != nil {
                            RemoteImage(url: member.photo, maxPixel: 400)
                        } else {
                            Image(systemName: "person.fill").font(.system(size: 54)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(width: 170, height: 170)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(member.name).font(.system(size: 40, weight: .bold))
                        if let c = member.character {
                            Text("as \(c)").font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                        }
                        if let d = person?.description {
                            Text(d.prefix(1).uppercased() + d.dropFirst())
                                .font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .frame(height: 170)
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 70)

                if let person {
                    if person.sections.isEmpty {
                        Text("Couldn't find other work for \(member.name).")
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, Theme.gutter)
                    }
                    ForEach(person.sections) { section in
                        DiscoveryRow(section: section)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finding \(member.name)'s work…").foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, Theme.gutter)
                }
                Color.clear.frame(height: 30)
            }
        }
        .scrollIndicators(.never)
        .task(id: member.name) {
            person = await DiscoveryService.person(member, context: context)
        }
    }
}

/// A titled row of posters from a discovery section (person credits, related titles).
struct DiscoveryRow: View {
    let section: DiscoveryService.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: section.title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(section.items) { meta in
                        PosterCard(meta: meta, caption: section.captions[meta.id])
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 12)
            }
        }
    }
}
