import 'package:flutter/material.dart';
import 'package:music_remote_app/core/models/track_metadata.dart';
import 'package:music_remote_app/features/home/presentation/widgets/playback_queue_card.dart';
import 'package:music_remote_app/features/home/presentation/widgets/transport_card.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_snapshot.dart';

class PlayerTab extends StatelessWidget {
  const PlayerTab({
    required this.metadata,
    required this.metadataLoading,
    required this.currentTrack,
    required this.statusText,
    required this.position,
    required this.duration,
    required this.volume,
    required this.isSeeking,
    required this.commandBusy,
    required this.commandStatus,
    required this.queueSnapshot,
    required this.shuffle,
    required this.repeatMode,
    required this.formatDuration,
    required this.resolveTrackTitle,
    required this.onSeekPreviewChanged,
    required this.onSeekTo,
    required this.onVolumeChanged,
    required this.onVolumeCommitted,
    required this.onPrev,
    required this.onPlay,
    required this.onPause,
    required this.onResume,
    required this.onNext,
    required this.onCycleRepeatMode,
    required this.onToggleShuffle,
    required this.onClearQueue,
    required this.onRemoveQueueEntry,
    required this.onReorderQueueEntry,
    super.key,
  });

  final TrackMetadata? metadata;
  final bool metadataLoading;
  final String currentTrack;
  final String statusText;
  final double position;
  final double duration;
  final double volume;
  final bool isSeeking;
  final bool commandBusy;
  final String commandStatus;
  final PlaybackQueueSnapshot queueSnapshot;
  final bool shuffle;
  final String repeatMode;
  final String Function(double seconds) formatDuration;
  final String Function(String trackId) resolveTrackTitle;
  final ValueChanged<double> onSeekPreviewChanged;
  final Future<void> Function(double value) onSeekTo;
  final ValueChanged<double> onVolumeChanged;
  final Future<void> Function(double value) onVolumeCommitted;
  final Future<void> Function() onPrev;
  final Future<void> Function() onPlay;
  final Future<void> Function() onPause;
  final Future<void> Function() onResume;
  final Future<void> Function() onNext;
  final Future<void> Function() onCycleRepeatMode;
  final Future<void> Function() onToggleShuffle;
  final Future<void> Function() onClearQueue;
  final Future<void> Function(String entryId) onRemoveQueueEntry;
  final void Function(int oldIndex, int newIndex) onReorderQueueEntry;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _trackMetadataCard(context),
      const SizedBox(height: 12),
      _nowPlayingCard(context),
      const SizedBox(height: 12),
      TransportCard(
        queueSnapshot: queueSnapshot,
        commandBusy: commandBusy,
        currentTrackTitle: queueSnapshot.currentTrackId == null
            ? 'none'
            : resolveTrackTitle(queueSnapshot.currentTrackId!),
        isPlaying: statusText.toLowerCase() == 'playing',
        isPaused: statusText.toLowerCase() == 'paused',
        shuffleEnabled: shuffle,
        repeatMode: repeatMode,
        canGoNext:
            queueSnapshot.canGoNext ||
            (repeatMode == 'all' && queueSnapshot.currentTrackId != null),
        commandStatus: commandStatus,
        onPrev: onPrev,
        onPlay: onPlay,
        onPause: onPause,
        onResume: onResume,
        onNext: onNext,
        onCycleRepeatMode: onCycleRepeatMode,
        onToggleShuffle: onToggleShuffle,
      ),
      const SizedBox(height: 12),
      PlaybackQueueCard(
        queueSnapshot: queueSnapshot,
        commandBusy: commandBusy,
        onClearQueue: onClearQueue,
        onRemoveQueueEntry: onRemoveQueueEntry,
        onReorderQueueEntry: onReorderQueueEntry,
      ),
    ],
  );

  Widget _nowPlayingCard(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Now Playing', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(currentTrack, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 8),
          Text('Status: $statusText'),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(formatDuration(position)),
              const Spacer(),
              Text(formatDuration(duration)),
            ],
          ),
          Slider(
            value: (duration <= 0 ? 0 : position.clamp(0, duration)).toDouble(),
            max: duration > 0 ? duration : 1,
            onChanged: duration > 0 ? onSeekPreviewChanged : null,
            onChangeEnd: duration > 0 ? onSeekTo : null,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.volume_up),
              Expanded(
                child: Slider(
                  value: volume,
                  max: 100,
                  divisions: 100,
                  label: volume.round().toString(),
                  onChanged: onVolumeChanged,
                  onChangeEnd: onVolumeCommitted,
                ),
              ),
              Text('${volume.round()}%'),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _trackMetadataCard(BuildContext context) {
    final title = metadata?.title ?? currentTrack;
    final subtitle = metadata?.artist ?? 'Unknown artist';

    ImageProvider<Object>? coverProvider;
    if (metadata?.coverBytes != null) {
      coverProvider = MemoryImage(metadata!.coverBytes!);
    } else if ((metadata?.coverUrl ?? '').isNotEmpty) {
      coverProvider = NetworkImage(metadata!.coverUrl!);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 110,
                    height: 110,
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: coverProvider == null
                        ? const Icon(Icons.album, size: 48)
                        : Image(image: coverProvider, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (metadataLoading) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _metaChip('Album', _metadataValue(metadata?.album)),
                _metaChip('Year', _metadataValue(metadata?.year)),
                _metaChip(
                  'Bitrate',
                  metadata?.bitrate != null ? '${metadata!.bitrate} kbps' : '-',
                ),
                _metaChip('Source', _metadataValue(metadata?.source)),
                _metaChip('Found', metadata?.found ?? false ? 'yes' : 'no'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaChip(String label, String value) =>
      Chip(label: Text('$label: $value'), visualDensity: VisualDensity.compact);

  String _metadataValue(Object? value, {String fallback = '-'}) {
    if (value == null) {
      return fallback;
    }
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }
}
