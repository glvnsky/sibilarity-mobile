import 'dart:async';

import 'package:flutter/material.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_snapshot.dart';

class TransportCard extends StatelessWidget {
  const TransportCard({
    required this.queueSnapshot,
    required this.commandBusy,
    required this.transportLocked,
    required this.libraryIsEmpty,
    required this.currentTrackTitle,
    required this.hasCurrentPlayback,
    required this.commandStatus,
    required this.onPrev,
    required this.onPlay,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    required this.onNext,
    super.key,
  });

  final PlaybackQueueSnapshot queueSnapshot;
  final bool commandBusy;
  final bool transportLocked;
  final bool libraryIsEmpty;
  final String currentTrackTitle;
  final bool hasCurrentPlayback;
  final String commandStatus;
  final Future<void> Function() onPrev;
  final Future<void> Function() onPlay;
  final Future<void> Function() onPause;
  final Future<void> Function() onResume;
  final Future<void> Function() onStop;
  final Future<void> Function() onNext;

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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: commandBusy || !queueSnapshot.canGoPrev
                    ? null
                    : () => unawaited(onPrev()),
                icon: const Icon(Icons.skip_previous),
                label: const Text('Prev'),
              ),
              FilledButton.icon(
                onPressed:
                    commandBusy ||
                        transportLocked ||
                        (queueSnapshot.isEmpty && libraryIsEmpty)
                    ? null
                    : () => unawaited(onPlay()),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play'),
              ),
              FilledButton.icon(
                onPressed: commandBusy ? null : () => unawaited(onPause()),
                icon: const Icon(Icons.pause),
                label: const Text('Pause'),
              ),
              FilledButton.icon(
                onPressed: commandBusy ? null : () => unawaited(onResume()),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Resume'),
              ),
              FilledButton.tonalIcon(
                onPressed: commandBusy || !hasCurrentPlayback
                    ? null
                    : () => unawaited(onStop()),
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
              FilledButton.tonalIcon(
                onPressed: commandBusy || !queueSnapshot.canGoNext
                    ? null
                    : () => unawaited(onNext()),
                icon: const Icon(Icons.skip_next),
                label: const Text('Next'),
              ),
            ],
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
