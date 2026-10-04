// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData
import SwiftSonic

/// Settings → Manage Downloads: every album on the server, marked downloaded or not, with
/// Download All and Delete All.
struct ManageDownloadsView: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        Group {
            if let container, let serverId = container.serverState.activeServer?.id {
                ManageDownloadsContent(
                    vm: AlbumDownloadsViewModel(
                        libraryService: container.libraryService,
                        downloadService: container.downloadService,
                        modelContainer: container.modelContainer,
                        serverId: serverId
                    ),
                    serverId: serverId
                )
            } else {
                EmptyStateView(
                    systemImage: "arrow.down.circle",
                    title: "No Server",
                    subtitle: "Connect to a server to manage downloads."
                )
            }
        }
        .navigationTitle("Manage Downloads")
    }
}

private struct ManageDownloadsContent: View {
    @State private var vm: AlbumDownloadsViewModel
    @Query private var tracks: [DownloadedTrack]
    @State private var filter: AlbumDownloadFilter = .all
    @State private var searchText = ""
    @State private var confirmingDownloadAll = false
    @State private var confirmingDeleteAll = false

    init(vm: AlbumDownloadsViewModel, serverId: UUID) {
        _vm = State(initialValue: vm)
        let sid = serverId
        _tracks = Query(filter: #Predicate<DownloadedTrack> { $0.serverId == sid })
    }

    /// Downloaded tracks per album, live: rows update as a download lands.
    private var downloadedCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for track in tracks {
            if let albumId = track.albumId { counts[albumId, default: 0] += 1 }
        }
        return counts
    }

    var body: some View {
        let counts = downloadedCounts
        let statuses = Dictionary(uniqueKeysWithValues: vm.albums.map {
            ($0.id, AlbumDownloadStatus(downloaded: counts[$0.id] ?? 0, songCount: $0.songCount))
        })
        let missing = vm.albums.filter { statuses[$0.id]?.isComplete != true }
        let withDownloads = vm.albums.filter { statuses[$0.id]?.hasAnything == true }

        Group {
            switch vm.loadState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                EmptyStateView(
                    systemImage: "wifi.exclamationmark",
                    title: "Couldn't load albums",
                    subtitle: LocalizedStringKey(message),
                    action: .init(label: "Retry") { Task { await vm.load() } }
                )
            case .loaded:
                list(statuses: statuses, missing: missing, withDownloads: withDownloads)
            }
        }
        .task { await vm.load() }
        .confirmationDialog(
            "Download \(missing.count) albums?",
            isPresented: $confirmingDownloadAll,
            titleVisibility: .visible
        ) {
            Button("Download All") { vm.downloadAll(missing) }
        } message: {
            Text("Downloads every album not yet on this device. Keep Cassette open while it runs.")
        }
        .confirmationDialog(
            "Delete \(withDownloads.count) downloaded albums?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { Task { await vm.deleteAll() } }
        } message: {
            Text("Removes the downloaded files from this device. The albums stay on your server.")
        }
    }

    private func list(
        statuses: [String: AlbumDownloadStatus],
        missing: [AlbumID3],
        withDownloads: [AlbumID3]
    ) -> some View {
        let shown = vm.albums.filter { album in
            guard let status = statuses[album.id], filter.includes(status) else { return false }
            guard !searchText.isEmpty else { return true }
            return album.name.localizedCaseInsensitiveContains(searchText)
                || (album.artist?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
        let completeCount = vm.albums.count - missing.count

        return List {
            Section {
                summary(complete: completeCount)
                actions(missing: missing, withDownloads: withDownloads)
            }

            Section {
                Picker("Show", selection: $filter) {
                    ForEach(AlbumDownloadFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                if shown.isEmpty {
                    Text(searchText.isEmpty ? "No albums here." : "No matching albums.")
                        .font(.cassetteCellSubtitle)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shown, id: \.id) { album in
                        AlbumDownloadRow(
                            album: album,
                            status: statuses[album.id] ?? .notDownloaded,
                            isDownloading: vm.downloadingIds.contains(album.id)
                                || vm.bulkCurrentId == album.id,
                            onDownload: { Task { await vm.download(album) } },
                            onDelete: { Task { await vm.delete(albumId: album.id) } }
                        )
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Albums or artists")
        .refreshable { await vm.load() }
        .miniPlayerBottomMargin()
    }

    private func summary(complete: Int) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
            Text("\(complete) of \(vm.albums.count) albums downloaded")
                .font(.cassetteCellTitle)
            ProgressView(value: Double(complete), total: Double(max(vm.albums.count, 1)))
                .tint(.green)
            if vm.isDownloadingAll {
                Text("Downloading \(vm.bulkDone + 1) of \(vm.bulkTotal)\(vm.bulkCurrentName.map { " — \($0)" } ?? "")")
                    .font(.cassetteCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, CassetteSpacing.xs)
    }

    @ViewBuilder
    private func actions(missing: [AlbumID3], withDownloads: [AlbumID3]) -> some View {
        if vm.isDownloadingAll {
            Button(role: .cancel) { vm.cancelDownloadAll() } label: {
                Label("Stop Downloading", systemImage: "stop.circle")
            }
        } else {
            Button { confirmingDownloadAll = true } label: {
                Label("Download All (\(missing.count))", systemImage: "arrow.down.circle")
            }
            .disabled(missing.isEmpty)
        }

        Button(role: .destructive) { confirmingDeleteAll = true } label: {
            if vm.isDeletingAll {
                HStack(spacing: CassetteSpacing.s) {
                    ProgressView()
                    Text("Deleting…")
                }
            } else {
                Label("Delete All (\(withDownloads.count))", systemImage: "trash")
            }
        }
        .disabled(withDownloads.isEmpty || vm.isDeletingAll || vm.isDownloadingAll)
    }
}

// MARK: - Row

private struct AlbumDownloadRow: View {
    let album: AlbumID3
    let status: AlbumDownloadStatus
    let isDownloading: Bool
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: CassetteSpacing.m) {
            NavigationLink(value: HomeDestination.albumById(
                id: album.id,
                name: album.name,
                subtitle: album.artist ?? "",
                coverArtId: album.coverArt,
                hasZoomSource: false
            )) {
                HStack(spacing: CassetteSpacing.m) {
                    CoverArtCard(id: album.coverArt ?? album.id, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.name)
                            .font(.cassetteCellTitle)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.cassetteCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            trailing
        }
        .swipeActions {
            if status.hasAnything {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }

    private var subtitle: String {
        let artist = album.artist ?? String(localized: "Unknown Artist")
        switch status {
        case .downloaded:
            return "\(artist) · \(String(localized: "Downloaded"))"
        case .partial(let downloaded, let total):
            return "\(artist) · \(downloaded)/\(total) \(String(localized: "tracks"))"
        case .notDownloaded:
            return "\(artist) · \(album.songCount) \(String(localized: "tracks"))"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isDownloading {
            ProgressView()
                .accessibilityLabel("Downloading")
        } else {
            switch status {
            case .downloaded:
                // Not a button: deleting goes through the swipe action, never one stray tap.
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Downloaded")
            case .partial:
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.title3)
                        .foregroundStyle(Color.cassetteAccent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Partly downloaded. Download the rest")
            case .notDownloaded:
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(Color.cassetteAccent)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download album")
            }
        }
    }
}
