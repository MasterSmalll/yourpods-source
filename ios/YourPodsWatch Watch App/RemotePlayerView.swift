import SwiftUI

struct RemotePlayerView: View {
    @EnvironmentObject var sessionManager: WatchSessionManager
    
    var body: some View {
        VStack {
            Spacer()
            
            Text(sessionManager.remoteTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Text(sessionManager.remoteArtist)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Spacer()
            
            HStack(spacing: 30) {
                Button(action: {
                    sessionManager.sendRemoteCommand("skipBackward")
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }
                
                Button(action: {
                    sessionManager.sendRemoteCommand(sessionManager.remoteIsPlaying ? "pause" : "play")
                }) {
                    Image(systemName: sessionManager.remoteIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                }
                
                Button(action: {
                    sessionManager.sendRemoteCommand("skipForward")
                }) {
                    Image(systemName: "goforward.30")
                        .font(.title2)
                }
            }
            .padding(.bottom)
            
            Spacer()
        }
        .navigationTitle("Now Playing")
    }
}
