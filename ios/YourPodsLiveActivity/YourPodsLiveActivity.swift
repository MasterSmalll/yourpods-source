//
//  YourPodsLiveActivity.swift
//  YourPodsLiveActivity
//
//  Created by YourPods on 2/7/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - App Group shared UserDefaults

let sharedDefault = UserDefaults(suiteName: "group.com.asecretcompany.yourpods")!

// MARK: - ActivityAttributes (MUST be named LiveActivitiesAppAttributes)

struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable {
    public typealias LiveDeliveryData = ContentState
    
    public struct ContentState: Codable, Hashable { }
    
    var id = UUID()
}

extension LiveActivitiesAppAttributes {
    func prefixedKey(_ key: String) -> String {
        return "\(id)_\(key)"
    }
}

// MARK: - Helper to format seconds as mm:ss

private func formatTime(_ totalSeconds: Int) -> String {
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

// MARK: - Live Activity Widget

struct YourPodsNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
            // ── Lock Screen / Banner View ──
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // ── Expanded Regions ──
                DynamicIslandExpandedRegion(.leading) {
                    ArtworkView(context: context, size: 60)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PlayPauseButton(context: context, size: 36)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(episodeTitle(context))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(podcastName(context))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        // Progress bar
                        ProgressView(value: progressFraction(context))
                            .tint(.green)
                        
                        // Time labels
                        HStack {
                            Text(formatTime(positionSeconds(context)))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatTime(durationSeconds(context)))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        
                        // Playback controls
                        HStack(spacing: 32) {
                            Link(destination: URL(string: "yourpods://action/skipBackward")!) {
                                Image(systemName: "gobackward.15")
                                    .font(.title3)
                                    .foregroundColor(.white)
                            }
                            
                            PlayPauseButton(context: context, size: 40)
                            
                            Link(destination: URL(string: "yourpods://action/skipForward")!) {
                                Image(systemName: "goforward.30")
                                    .font(.title3)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                // ── Compact Leading: small artwork ──
                ArtworkView(context: context, size: 24)
            } compactTrailing: {
                // ── Compact Trailing: play/pause icon ──
                PlayPauseIcon(context: context, size: 14)
            } minimal: {
                // ── Minimal: just the artwork ──
                ArtworkView(context: context, size: 24)
            }
        }
    }
}

// MARK: - Lock Screen Banner View

struct LockScreenView: View {
    let context: ActivityViewContext<LiveActivitiesAppAttributes>
    
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(context: context, size: 50)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(episodeTitle(context))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(podcastName(context))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                ProgressView(value: progressFraction(context))
                    .tint(.green)
            }
            
            Spacer()
            
            HStack(spacing: 16) {
                Link(destination: URL(string: "yourpods://action/skipBackward")!) {
                    Image(systemName: "gobackward.15")
                        .font(.body)
                }
                
                Link(destination: URL(string: "yourpods://action/togglePlay")!) {
                    Image(systemName: isPlaying(context) ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                
                Link(destination: URL(string: "yourpods://action/skipForward")!) {
                    Image(systemName: "goforward.30")
                        .font(.body)
                }
            }
            .foregroundColor(.white)
        }
        .padding(12)
        .activityBackgroundTint(.black.opacity(0.8))
    }
}

// MARK: - Reusable Sub-views

struct ArtworkView: View {
    let context: ActivityViewContext<LiveActivitiesAppAttributes>
    let size: CGFloat
    
    var body: some View {
        if let artPath = sharedDefault.string(forKey: context.attributes.prefixedKey("artUri")),
           let uiImage = UIImage(contentsOfFile: artPath) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .cornerRadius(size > 30 ? 8 : 4)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size > 30 ? 8 : 4)
                    .fill(Color.gray.opacity(0.3))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.5))
                    .foregroundColor(.gray)
            }
            .frame(width: size, height: size)
        }
    }
}

struct PlayPauseButton: View {
    let context: ActivityViewContext<LiveActivitiesAppAttributes>
    let size: CGFloat
    
    var body: some View {
        Link(destination: URL(string: "yourpods://action/togglePlay")!) {
            Image(systemName: isPlaying(context) ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: size))
                .foregroundColor(.green)
        }
    }
}

struct PlayPauseIcon: View {
    let context: ActivityViewContext<LiveActivitiesAppAttributes>
    let size: CGFloat
    
    var body: some View {
        Image(systemName: isPlaying(context) ? "pause.fill" : "play.fill")
            .font(.system(size: size))
            .foregroundColor(.green)
    }
}

// MARK: - Data Accessors (read from shared UserDefaults)

private func episodeTitle(_ context: ActivityViewContext<LiveActivitiesAppAttributes>) -> String {
    return sharedDefault.string(forKey: context.attributes.prefixedKey("episodeTitle")) ?? "Episode"
}

private func podcastName(_ context: ActivityViewContext<LiveActivitiesAppAttributes>) -> String {
    return sharedDefault.string(forKey: context.attributes.prefixedKey("podcastName")) ?? "Podcast"
}

private func isPlaying(_ context: ActivityViewContext<LiveActivitiesAppAttributes>) -> Bool {
    return sharedDefault.bool(forKey: context.attributes.prefixedKey("isPlaying"))
}

private func positionSeconds(_ context: ActivityViewContext<LiveActivitiesAppAttributes>) -> Int {
    return sharedDefault.integer(forKey: context.attributes.prefixedKey("positionSeconds"))
}

private func durationSeconds(_ context: ActivityViewContext<LiveActivitiesAppAttributes>) -> Int {
    let d = sharedDefault.integer(forKey: context.attributes.prefixedKey("durationSeconds"))
    return d > 0 ? d : 1 // Avoid division by zero
}

private func progressFraction(_ context: ActivityViewContext<LiveActivitiesAppAttributes>) -> Double {
    let p = sharedDefault.double(forKey: context.attributes.prefixedKey("progressFraction"))
    return min(max(p, 0.0), 1.0)
}
