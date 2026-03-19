import SwiftUI

/// Compact sheet for setting a sleep timer with presets and custom duration.
struct SleepTimerSheet: View {
    @Environment(SleepTimerManager.self) private var sleepTimer
    @Environment(\.dismiss) private var dismiss
    
    @State private var customMinutes: Int = 45
    @State private var showCustom = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if sleepTimer.isActive {
                    activeTimerView
                } else {
                    presetView
                }
            }
            .padding()
            .navigationTitle("Sleep Timer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    // MARK: - Active Timer
    
    private var activeTimerView: some View {
        VStack(spacing: 20) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 48))
                .foregroundStyle(.indigo)
            
            Text(sleepTimer.formattedRemaining)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
            
            Text("remaining")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 16) {
                Button {
                    sleepTimer.extend(minutes: 5)
                } label: {
                    Label("+5 min", systemImage: "plus.circle")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                
                Button {
                    sleepTimer.extend(minutes: 15)
                } label: {
                    Label("+15 min", systemImage: "plus.circle")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            }
            
            Button(role: .destructive) {
                sleepTimer.stop()
            } label: {
                Text("Cancel Timer")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.red.opacity(0.15))
                    .foregroundColor(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    
    // MARK: - Presets
    
    private var presetView: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 40))
                .foregroundStyle(.indigo)
            
            Text("Stop playing after")
                .font(.headline)
            
            // Preset buttons
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(SleepTimerManager.presets, id: \.self) { minutes in
                    Button {
                        sleepTimer.start(minutes: minutes)
                        dismiss()
                    } label: {
                        Text("\(minutes) min")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.indigo.opacity(0.15))
                            .foregroundColor(.indigo)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            
            Divider()
            
            // Custom duration
            VStack(spacing: 12) {
                Text("Custom Duration")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                HStack {
                    Button {
                        customMinutes = max(1, customMinutes - 5)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title2)
                    }
                    
                    Text("\(customMinutes) min")
                        .font(.title2.bold().monospacedDigit())
                        .frame(minWidth: 80)
                    
                    Button {
                        customMinutes = min(480, customMinutes + 5)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }
                .foregroundStyle(.indigo)
                
                Button {
                    sleepTimer.start(minutes: customMinutes)
                    dismiss()
                } label: {
                    Text("Start Custom Timer")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.indigo)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}
