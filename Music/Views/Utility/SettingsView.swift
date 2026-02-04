import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var deleteSettings = DeleteSettings.load()
    let onManualSync: (() async -> (before: Int, after: Int))?

    @State private var showMusicPicker = false
    @State private var showFolderPicker = false
    @State private var isImporting = false
    @State private var showImportAlert = false
    @State private var importAlertMessage = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(Localized.appearance) {
                    Toggle(Localized.minimalistLibraryIcons, isOn: $deleteSettings.minimalistIcons)
                        .onChange(of: deleteSettings.minimalistIcons) { _, _ in
                            deleteSettings.save()
                        }

                    Toggle(Localized.forceDarkMode, isOn: $deleteSettings.forceDarkMode)
                        .onChange(of: deleteSettings.forceDarkMode) { _, _ in
                            deleteSettings.save()
                        }
                }
                
                Section(Localized.library) {
                    Button {
                        guard !isImporting else { return }
                        showMusicPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: 20))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(Localized.addSongs)
                                Text(Localized.importMusicFiles)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if isImporting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isImporting)

                    Button {
                        guard !isImporting else { return }
                        showFolderPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: 20))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(Localized.openFolder)
                                Text(Localized.importMusicFolder)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if isImporting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isImporting)
                }
                
                Section(Localized.audioSettings) {
                    NavigationLink(destination: EQSettingsView()) {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundColor(.blue)
                                .font(.system(size: 20))
                            Text(Localized.graphicEqualizer)
                        }
                    }

                    Toggle(Localized.crossfadeEnabled, isOn: $deleteSettings.crossfadeEnabled)
                        .onChange(of: deleteSettings.crossfadeEnabled) { _, _ in
                            deleteSettings.save()
                        }

                    if deleteSettings.crossfadeEnabled {
                        HStack {
                            Text(Localized.crossfadeDuration)
                            Spacer()
                            Text("\(deleteSettings.crossfadeDuration, specifier: "%.1f")\(Localized.secondsShort)")
                                .foregroundColor(.secondary)
                        }

                        Slider(
                            value: $deleteSettings.crossfadeDuration,
                            in: 0.1...12.0,
                            step: 0.1
                        )
                        .onChange(of: deleteSettings.crossfadeDuration) { _, _ in
                            deleteSettings.save()
                        }
                    }
                }

                Section(Localized.player) {
                    NavigationLink(destination: WeightedShuffleSettingsView()) {
                        HStack {
                            Image(systemName: "shuffle")
                                .foregroundColor(.blue)
                                .font(.system(size: 20))
                            Text(Localized.weightedShuffle)
                        }
                    }
                }

            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 100)
            }
            .navigationTitle(Localized.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.done) {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showMusicPicker) {
            MusicFilePicker { urls in
                importFiles(urls)
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            MusicFolderPicker { folderURL in
                importFolder(folderURL)
            }
        }
        .alert(Localized.library, isPresented: $showImportAlert) {
            Button(Localized.ok) {}
        } message: {
            Text(importAlertMessage)
        }
    }

    private func importFiles(_ urls: [URL]) {
        isImporting = true

        Task {
            let processedCount = await ExternalImportManager.shared.importFiles(urls: urls)

            await MainActor.run {
                isImporting = false
                importAlertMessage = processedCount == 1 ? "1 track processed" : "\(processedCount) tracks processed"
                showImportAlert = true
            }
        }
    }

    private func importFolder(_ folderURL: URL) {
        isImporting = true

        Task {
            let processedCount = await ExternalImportManager.shared.importFolder(folderURL)

            await MainActor.run {
                isImporting = false
                importAlertMessage = processedCount == 1 ? "1 track processed" : "\(processedCount) tracks processed"
                showImportAlert = true
            }
        }
    }
}

#Preview {
    SettingsView(onManualSync: nil)
}
