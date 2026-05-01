import 'dart:async';

import 'package:flutter/material.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_snapshot.dart';

class TransportCard extends StatelessWidget {
  const TransportCard({
    required this.queueSnapshot,
    required this.commandBusy,
    required this.currentTrackTitle,
    required this.isPlaying,
    required this.isPaused,
    required this.shuffleEnabled,
    required this.repeatMode,
    required this.canGoNext,
    required this.commandStatus,
    required this.onPrev,
    required this.onPlay,
    required this.onPause,
    required this.onResume,
    required this.onNext,
    required this.onCycleRepeatMode,
    required this.onToggleShuffle,
    super.key,
  });

  final PlaybackQueueSnapshot queueSnapshot;
  final bool commandBusy;
  final String currentTrackTitle;
  final bool isPlaying;
  final bool isPaused;
  final bool shuffleEnabled;
  final String repeatMode;
  final bool canGoNext;
  final String commandStatus;
  final Future<void> Function() onPrev;
  final Future<void> Function() onPlay;
  final Future<void> Function() onPause;
  final Future<void> Function() onResume;
  final Future<void> Function() onNext;
  final Future<void> Function() onCycleRepeatMode;
  final Future<void> Function() onToggleShuffle;

  bool get _showPauseAction => isPlaying;
  bool get _showResumeAction => isPaused;

  static const double _transportButtonSize = 56;

  bool get _repeatEnabled => repeatMode != 'off';

  IconData get _repeatIcon => switch (repeatMode) {
    'one' => Icons.repeat_one,
    'all' => Icons.repeat,
    _ => Icons.repeat,
  };

  String get _repeatTooltip => switch (repeatMode) {
    'one' => 'Repeat one',
    'all' => 'Repeat all',
    _ => 'Repeat off',
  };

  IconData get _shuffleIcon => Icons.shuffle;

  String get _shuffleTooltip => shuffleEnabled ? 'Shuffle on' : 'Shuffle off';

  ButtonStyle _modeButtonStyle(BuildContext context, {required bool active}) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton.styleFrom(
      backgroundColor: active
          ? colorScheme.secondaryContainer
          : colorScheme.surfaceContainerHighest,
      foregroundColor: active
          ? colorScheme.onSecondaryContainer
          : colorScheme.outline,
    );
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Transport', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(
            queueSnapshot.currentTrackId == null
                ? 'Current queue track: none'
                : 'Current queue track: $currentTrackTitle',
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              const totalButtonsWidth = _transportButtonSize * 5;
              final freeWidth = constraints.maxWidth - totalButtonsWidth;
              final spacing = freeWidth > 0 ? freeWidth / 4 : 8.0;

              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Tooltip(
                    message: _repeatTooltip,
                    child: SizedBox.square(
                      dimension: _transportButtonSize,
                      child: IconButton.filledTonal(
                        style: _modeButtonStyle(
                          context,
                          active: _repeatEnabled,
                        ),
                        onPressed: commandBusy
                            ? null
                            : () => unawaited(onCycleRepeatMode()),
                        icon: Icon(_repeatIcon),
                      ),
                    ),
                  ),
                  SizedBox(width: spacing),
                  SizedBox.square(
                    dimension: _transportButtonSize,
                    child: IconButton.filledTonal(
                      tooltip: 'Previous',
                      onPressed: commandBusy || !queueSnapshot.canGoPrev
                          ? null
                          : () => unawaited(onPrev()),
                      icon: const Icon(Icons.skip_previous),
                    ),
                  ),
                  SizedBox(width: spacing),
                  SizedBox.square(
                    dimension: _transportButtonSize,
                    child: IconButton.filled(
                      tooltip: _showPauseAction
                          ? 'Pause'
                          : (_showResumeAction ? 'Resume' : 'Play'),
                      onPressed: commandBusy || queueSnapshot.isEmpty
                          ? null
                          : () => unawaited(
                              _showPauseAction
                                  ? onPause()
                                  : (_showResumeAction ? onResume() : onPlay()),
                            ),
                      icon: Icon(_showPauseAction ? Icons.pause : Icons.play_arrow),
                    ),
                  ),
                  SizedBox(width: spacing),
                  SizedBox.square(
                    dimension: _transportButtonSize,
                    child: IconButton.filledTonal(
                      tooltip: 'Next',
                      onPressed: commandBusy || !canGoNext
                          ? null
                          : () => unawaited(onNext()),
                      icon: const Icon(Icons.skip_next),
                    ),
                  ),
                  SizedBox(width: spacing),
                  Tooltip(
                    message: _shuffleTooltip,
                    child: SizedBox.square(
                      dimension: _transportButtonSize,
                      child: IconButton.filledTonal(
                        style: _modeButtonStyle(
                          context,
                          active: shuffleEnabled,
                        ),
                        onPressed: commandBusy
                            ? null
                            : () => unawaited(onToggleShuffle()),
                        icon: Icon(_shuffleIcon),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            commandBusy ? 'Applying command...' : commandStatus,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
