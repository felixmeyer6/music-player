import SwiftUI

struct WeightedShuffleSettingsView: View {
    @State private var settings = WeightedShuffleSettings()

    var body: some View {
        Form {
            Section {
                Toggle(Localized.enableWeightedShuffle, isOn: $settings.isEnabled)
                    .tint(.blue)
                    .onChange(of: settings.isEnabled) { _, _ in
                        settings.save()
                    }
            }

            if settings.isEnabled {
                Section {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(0..<5, id: \.self) { index in
                            VStack(spacing: 8) {
                                VerticalWeightSlider(value: $settings.ratingWeights[index])
                                    .onChange(of: settings.ratingWeights[index]) { _, _ in
                                        settings.save()
                                    }

                                Text("\(Int(settings.ratingWeights[index] * 100))%")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(colorForWeight(settings.ratingWeights[index]))

                                HStack(spacing: 1) {
                                    Text("\(index + 1)")
                                        .font(.caption2)
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 8))
                                }
                                .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } header: {
                    Text(Localized.ratingWeights)
                } footer: {
                    Text(Localized.weightedShuffleDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(Localized.weightedShuffle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            settings = WeightedShuffleSettings.load()
        }
    }

    private func colorForWeight(_ weight: Double) -> Color {
        if weight < 0.3 {
            return .red
        } else if weight < 0.7 {
            return .yellow
        } else {
            return .green
        }
    }
}

private struct VerticalWeightSlider: View {
    @Binding var value: Double

    var body: some View {
        Slider(value: $value, in: 0.0...1.0, step: 0.05)
            .frame(width: 180)
            .rotationEffect(.degrees(-90))
            .frame(width: 40, height: 180)
    }
}
