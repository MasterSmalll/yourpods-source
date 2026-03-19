import SwiftUI

/// Per-podcast settings sheet. Port of podcast_settings_sheet.dart.
struct PodcastSettingsSheet: View {
    @Bindable var podcast: Podcast
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Auto-Queue") {
                    Picker("Mode", selection: Binding(
                        get: { podcast.effectiveSettings.autoQueueMode ?? .off },
                        set: { podcast.effectiveSettings.autoQueueMode = $0 }
                    )) {
                        Text("Off").tag(AutoQueueMode.off)
                        Text("Normal").tag(AutoQueueMode.normal)
                        Text("Priority").tag(AutoQueueMode.priority)
                    }
                }
                
                Section("Playback") {
                    Stepper(
                        "Skip Intro: \(podcast.effectiveSettings.skipIntroSeconds ?? 0)s",
                        value: Binding(
                            get: { podcast.effectiveSettings.skipIntroSeconds ?? 0 },
                            set: { podcast.effectiveSettings.skipIntroSeconds = $0 > 0 ? $0 : nil }
                        ),
                        in: 0...120,
                        step: 5
                    )
                    
                    Stepper(
                        "Skip Outro: \(podcast.effectiveSettings.skipOutroSeconds ?? 0)s",
                        value: Binding(
                            get: { podcast.effectiveSettings.skipOutroSeconds ?? 0 },
                            set: { podcast.effectiveSettings.skipOutroSeconds = $0 > 0 ? $0 : nil }
                        ),
                        in: 0...120,
                        step: 5
                    )
                    
                    if let speed = podcast.effectiveSettings.playbackSpeed {
                        HStack {
                            Text("Speed Override")
                            Spacer()
                            Text("\(speed, specifier: "%.1f")×")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section("Auto-Download") {
                    Toggle("Download New Episodes", isOn: Binding(
                        get: { podcast.effectiveSettings.autoDownloadNewEpisodes ?? false },
                        set: { podcast.effectiveSettings.autoDownloadNewEpisodes = $0 }
                    ))
                    
                    Toggle("Remove After Play", isOn: Binding(
                        get: { podcast.effectiveSettings.removeDownloadAfterPlay ?? false },
                        set: { podcast.effectiveSettings.removeDownloadAfterPlay = $0 }
                    ))
                }
                
                Section("Completion") {
                    Toggle("Archive on Complete", isOn: Binding(
                        get: { podcast.effectiveSettings.archiveOnComplete ?? false },
                        set: { podcast.effectiveSettings.archiveOnComplete = $0 }
                    ))
                }
                
                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        podcast.effectiveSettings = PodcastSettings()
                    }
                }
            }
            .navigationTitle("Podcast Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
    }
}
