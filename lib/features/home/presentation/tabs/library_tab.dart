import 'package:flutter/material.dart';
import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/features/home/presentation/widgets/library_card.dart';

class LibraryTab extends StatelessWidget {
  const LibraryTab({
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
  Widget build(BuildContext context) => LibraryCard(
    library: library,
    uploading: uploading,
    uploadProgress: uploadProgress,
    onRefreshLibrary: onRefreshLibrary,
    onUploadTrack: onUploadTrack,
    onTrackTap: onTrackTap,
    onTrackAction: onTrackAction,
  );
}
