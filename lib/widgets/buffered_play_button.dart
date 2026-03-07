import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

/// A play/pause button with an animated circular progress ring that shows
/// buffering / loading state.
///
/// Visual states:
///  - **Loading** / **Buffering**: indeterminate spinning white ring
///  - **Playing with no audio data yet**: indeterminate spinning ring
///    (user tapped play but stream hasn't started flowing)
///  - **Ready / Paused / Idle**: no ring
///
/// Used in both the full player screen (large, with purple background) and
/// the mini player bar (small, no background).
class BufferedPlayButton extends StatelessWidget {
  /// Diameter of the button (e.g. 64 for full player, 32 for mini player).
  final double size;

  /// If true, draws a filled purple circle behind the icon (full player style).
  final bool showBackground;

  /// Called when the button is tapped.
  final VoidCallback onTap;

  /// The [AudioPlayer] instance to derive streams from.
  final AudioPlayer player;

  /// Whether the player is currently playing (drives play/pause icon).
  final bool isPlaying;

  const BufferedPlayButton({
    super.key,
    required this.size,
    required this.showBackground,
    required this.onTap,
    required this.player,
    required this.isPlaying,
  });

  bool _shouldShowRing(ProcessingState processingState, bool playing,
      Duration bufferedPosition, Duration? duration) {
    // Only show the ring when the user has actively triggered playback
    // but audio isn't flowing yet (loading/buffering with play intent).
    // This prevents the ring from flashing during fast initial source
    // setup — it only appears when there's a real stall or retry.
    if (!playing) return false;

    if (processingState == ProcessingState.loading ||
        processingState == ProcessingState.buffering) {
      return true;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = showBackground ? size * 0.5625 : size;
    // Ring sits outside the button with a small gap
    final ringSize = size + (showBackground ? 10 : 6);
    final strokeWidth = showBackground ? 3.5 : 2.5;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: ringSize,
        height: ringSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // The ring — nested StreamBuilders (avoids rxdart null issues)
            //
            // IMPORTANT: use AnimatedSwitcher + conditional mount, NOT
            // AnimatedOpacity. AnimatedOpacity(opacity: 0) keeps the
            // CircularProgressIndicator in the tree and its animation
            // Ticker running at 60fps, pinning the raster thread even
            // when the ring is invisible. By swapping to SizedBox.shrink()
            // when not needed, Flutter cancels the Ticker entirely.
            StreamBuilder<ProcessingState>(
              stream: player.processingStateStream,
              initialData: ProcessingState.idle,
              builder: (context, procSnap) {
                final procState = procSnap.data ?? ProcessingState.idle;

                return StreamBuilder<Duration>(
                  stream: player.bufferedPositionStream,
                  initialData: Duration.zero,
                  builder: (context, bufSnap) {
                    final buffered = bufSnap.data ?? Duration.zero;

                    return StreamBuilder<Duration?>(
                      stream: player.durationStream,
                      initialData: player.duration,
                      builder: (context, durSnap) {
                        final duration = durSnap.data;
                        final showRing = _shouldShowRing(
                            procState, isPlaying, buffered, duration);

                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: showRing
                              ? SizedBox(
                                  key: const ValueKey('ring'),
                                  width: ringSize,
                                  height: ringSize,
                                  child: CircularProgressIndicator(
                                    strokeWidth: strokeWidth,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                      Colors.white,
                                    ),
                                    backgroundColor:
                                        Colors.white.withOpacity(0.15),
                                  ),
                                )
                              : SizedBox(
                                  key: const ValueKey('no-ring'),
                                  width: ringSize,
                                  height: ringSize,
                                ),
                        );
                      },
                    );
                  },
                );
              },
            ),

            // The button itself
            if (showBackground)
              Container(
                height: size,
                width: size,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.deepPurpleAccent,
                ),
                child: Icon(
                  isPlaying ? Icons.pause : Icons.play_arrow,
                  size: iconSize,
                  color: Colors.white,
                ),
              )
            else
              Icon(
                isPlaying ? Icons.pause : Icons.play_arrow,
                size: iconSize,
                color: Colors.white,
              ),
          ],
        ),
      ),
    );
  }
}
