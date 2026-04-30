import 'dart:async';

import 'package:flutter/material.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_snapshot.dart';

class PlaybackQueueCard extends StatelessWidget {
  const PlaybackQueueCard({
    required this.queueSnapshot,
    required this.commandBusy,
    required this.onClearQueue,
    required this.onRemoveQueueEntry,
    required this.onReorderQueueEntry,
    super.key,
  });

  final PlaybackQueueSnapshot queueSnapshot;
  final bool commandBusy;
  final Future<void> Function() onClearQueue;
  final Future<void> Function(String entryId) onRemoveQueueEntry;
  final void Function(int oldIndex, int newIndex) onReorderQueueEntry;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Playback Queue (${queueSnapshot.items.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: commandBusy || queueSnapshot.isEmpty
                    ? null
                    : () => unawaited(onClearQueue()),
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (queueSnapshot.items.isEmpty)
            const Text(
              'Queue is empty. Use the library to start playback or add tracks.',
            )
          else
            SizedBox(
              height: 260,
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: queueSnapshot.items.length,
                onReorder: onReorderQueueEntry,
                itemBuilder: (context, index) {
                  final item = queueSnapshot.items[index];
                  return ListTile(
                    key: ValueKey<String>(item.entryId),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      item.isCurrent ? Icons.play_arrow : Icons.queue_music,
                    ),
                    title: Text(item.title),
                    subtitle: Text(item.trackId),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Remove from queue',
                          onPressed: commandBusy
                              ? null
                              : () =>
                                    unawaited(onRemoveQueueEntry(item.entryId)),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        ReorderableDelayedDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    ),
  );
}
