import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var deleteSettings = DeleteSettings.load()
    
    var body: some View {
        NavigationView {
            Form {
                Section(Localized.appearance) {
                    Toggle(Localized.minimalistLibraryIcons, isOn: $deleteSettings.minimalistIcons)
                        .onChange(of: deleteSettings.minimalistIcons) { _, _ in
                            deleteSettings.save()
                        }
                    
                    Text(Localized.useSimpleIcons)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Toggle(Localized.forceDarkMode, isOn: $deleteSettings.forceDarkMode)
                        .onChange(of: deleteSettings.forceDarkMode) { _, _ in
                            deleteSettings.save()
                        }
                    
                    Text(Localized.overrideSystemAppearance)
                        .font(.caption)
                        .foregroundColor(.secondary)
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

                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.dsdPlaybackMode)
                            .font(.headline)

                        Text(Localized.dsdPlaybackModeDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $deleteSettings.dsdPlaybackMode) {
                            ForEach(DSDPlaybackMode.allCases, id: \.self) { mode in
                                VStack(alignment: .leading) {
                                    Text(mode.displayName)
                                        .font(.body)
                                }
                                .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: deleteSettings.dsdPlaybackMode) { _, _ in
                            deleteSettings.save()
                        }

                        Text(deleteSettings.dsdPlaybackMode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
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
    }
}

#Preview {
    SettingsView()
}
