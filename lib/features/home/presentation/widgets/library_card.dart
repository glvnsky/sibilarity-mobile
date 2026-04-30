import 'dart:async';

import 'package:flutter/material.dart';
import 'package:music_remote_app/core/models/track_item.dart';

enum LibraryTrackAction {
  addToQueueStart,
  addAfterCurrent,
  addToQueueEnd,
}

class LibraryCard extends StatelessWidget {
  const LibraryCard({
    required this.library,
    required this.uploading,
    required this.uploadProgress,
    required this.onRefreshLibrary,
    required this.onUploadTrack,
    required this.onTrackTap,
    required this.onTrackAction,
    super.key,
  });

  final List<TrackItem> library;
  final bool uploading;
  final double uploadProgress;
  final Future<void> Function() onRefreshLibrary;
  final Future<void> Function() onUploadTrack;
  final Future<void> Function(TrackItem track) onTrackTap;
  final Future<void> Function(TrackItem track, LibraryTrackAction action)
  onTrackAction;

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
                'Tracks (${library.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh library',
                onPressed: uploading ? null : () => unawaited(onRefreshLibrary()),
                icon: const Icon(Icons.sync),
              ),
              IconButton(
                tooltip: 'Upload file',
                onPressed: uploading ? null : () => unawaited(onUploadTrack()),
                icon: const Icon(Icons.upload_file),
              ),
            ],
          ),
          if (uploading) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: uploadProgress),
            const SizedBox(height: 6),
            Text('Uploading... ${(uploadProgress * 100).toStringAsFixed(0)}%'),
          ],
          const SizedBox(height: 8),
          if (library.isEmpty)
            const Text('Library is empty or server returned no tracks.')
          else
            SizedBox(
              height: 420,
              child: ListView.builder(
                itemCount: library.length,
                itemBuilder: (context, index) {
                  final track = library[index];
                  return ListTile(
                    onTap: () => unawaited(onTrackTap(track)),
                    leading: const Icon(Icons.music_note),
                    title: Text(track.title),
                    subtitle: Text(track.id),
                    trailing: PopupMenuButton<LibraryTrackAction>(
                      onSelected: (action) =>
                          unawaited(onTrackAction(track, action)),
                      itemBuilder: (context) => const [
                        PopupMenuItem<LibraryTrackAction>(
                          value: LibraryTrackAction.addToQueueStart,
                          child: Text('Add to queue start'),
                        ),
                        PopupMenuItem<LibraryTrackAction>(
                          value: LibraryTrackAction.addAfterCurrent,
                          child: Text('Add after current'),
                        ),
                        PopupMenuItem<LibraryTrackAction>(
                          value: LibraryTrackAction.addToQueueEnd,
                          child: Text('Add to queue end'),
                        ),
                      ],
                      icon: const Icon(Icons.more_vert),
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
