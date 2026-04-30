class PlaybackQueueSnapshotItem {
  const PlaybackQueueSnapshotItem({
    required this.entryId,
    required this.trackId,
    required this.title,
    required this.isCurrent,
  });

  final String entryId;
  final String trackId;
  final String title;
  final bool isCurrent;
}

class PlaybackQueueSnapshot {
  const PlaybackQueueSnapshot({
    required this.items,
    required this.currentEntryId,
    required this.currentTrackId,
    required this.pendingLibraryBackTrackId,
    required this.historyLength,
    required this.canGoNext,
    required this.canGoPrev,
    required this.isEmpty,
  });

  final List<PlaybackQueueSnapshotItem> items;
  final String? currentEntryId;
  final String? currentTrackId;
  final String? pendingLibraryBackTrackId;
  final int historyLength;
  final bool canGoNext;
  final bool canGoPrev;
  final bool isEmpty;
}
