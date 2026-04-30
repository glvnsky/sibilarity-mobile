import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_snapshot.dart';
import 'package:music_remote_app/features/playback_queue/domain/queue_entry.dart';

class QueueCommandResult {
  const QueueCommandResult({
    required this.queueChanged,
    required this.shouldStopPlayback,
    this.trackIdToPlay,
  });

  const QueueCommandResult.noop()
    : queueChanged = false,
      shouldStopPlayback = false,
      trackIdToPlay = null;

  final bool queueChanged;
  final bool shouldStopPlayback;
  final String? trackIdToPlay;
}

class PlaybackQueueService {
  final Map<String, QueueEntry> _entriesById = <String, QueueEntry>{};
  final List<String> _historyTrackIds = <String>[];

  List<TrackItem> _library = const <TrackItem>[];
  Map<String, int> _libraryIndexByTrackId = const <String, int>{};
  int _entrySequence = 0;
  String? _headEntryId;
  String? _tailEntryId;
  String? _currentEntryId;
  String? _pendingLibraryBackTrackId;

  void setLibrary(List<TrackItem> library) {
    _library = List<TrackItem>.unmodifiable(library);
    _libraryIndexByTrackId = <String, int>{
      for (var index = 0; index < library.length; index += 1)
        library[index].id: index,
    };
  }

  PlaybackQueueSnapshot snapshot() {
    final items = <PlaybackQueueSnapshotItem>[];
    var entryId = _headEntryId;
    while (entryId != null) {
      final entry = _entriesById[entryId];
      if (entry == null) {
        break;
      }
      items.add(
        PlaybackQueueSnapshotItem(
          entryId: entry.entryId,
          trackId: entry.trackId,
          title: _resolveTrackTitle(entry.trackId),
          isCurrent: entry.entryId == _currentEntryId,
        ),
      );
      entryId = entry.nextEntryId;
    }

    final currentEntry = _currentEntry;
    return PlaybackQueueSnapshot(
      items: List<PlaybackQueueSnapshotItem>.unmodifiable(items),
      currentEntryId: _currentEntryId,
      currentTrackId: currentEntry?.trackId,
      pendingLibraryBackTrackId: _pendingLibraryBackTrackId,
      historyLength: _historyTrackIds.length,
      canGoNext: currentEntry?.nextEntryId != null,
      canGoPrev:
          _historyTrackIds.isNotEmpty ||
          currentEntry?.prevEntryId != null ||
          _pendingLibraryBackTrackId != null,
      isEmpty: items.isEmpty,
    );
  }

  QueueCommandResult rebuildFromLibraryClick(String trackId) {
    final startIndex = _libraryIndexByTrackId[trackId];
    if (startIndex == null) {
      return const QueueCommandResult.noop();
    }

    _resetQueue();

    for (final track in _library.skip(startIndex)) {
      _appendEntry(track.id);
    }

    _currentEntryId = _headEntryId;
    _pendingLibraryBackTrackId = startIndex > 0
        ? _library[startIndex - 1].id
        : null;

    return QueueCommandResult(
      queueChanged: true,
      shouldStopPlayback: false,
      trackIdToPlay: trackId,
    );
  }

  QueueCommandResult playOrBootstrapDefault() {
    if (_currentEntry != null) {
      return QueueCommandResult(
        queueChanged: false,
        shouldStopPlayback: false,
        trackIdToPlay: _currentEntry!.trackId,
      );
    }

    if (_headEntryId != null) {
      _currentEntryId = _headEntryId;
      return QueueCommandResult(
        queueChanged: true,
        shouldStopPlayback: false,
        trackIdToPlay: _currentEntry!.trackId,
      );
    }

    if (_library.isEmpty) {
      return const QueueCommandResult.noop();
    }

    return rebuildFromLibraryClick(_library.first.id);
  }

  QueueCommandResult advanceNext() {
    final currentEntry = _currentEntry;
    if (currentEntry == null) {
      return const QueueCommandResult.noop();
    }

    _historyTrackIds.add(currentEntry.trackId);
    final nextEntryId = currentEntry.nextEntryId;
    _unlinkEntry(currentEntry.entryId);
    _currentEntryId = nextEntryId;

    if (_currentEntry == null) {
      return const QueueCommandResult(
        queueChanged: true,
        shouldStopPlayback: true,
      );
    }

    return QueueCommandResult(
      queueChanged: true,
      shouldStopPlayback: false,
      trackIdToPlay: _currentEntry!.trackId,
    );
  }

  QueueCommandResult goBack() {
    if (_historyTrackIds.isNotEmpty) {
      final trackId = _historyTrackIds.removeLast();
      final restoredEntry = QueueEntry(
        entryId: _nextEntryId(),
        trackId: trackId,
      );

      final currentEntry = _currentEntry;
      if (currentEntry == null) {
        _appendExistingEntry(restoredEntry);
      } else {
        _insertEntryBefore(restoredEntry, currentEntry.entryId);
      }
      _currentEntryId = restoredEntry.entryId;

      return QueueCommandResult(
        queueChanged: true,
        shouldStopPlayback: false,
        trackIdToPlay: trackId,
      );
    }

    final currentEntry = _currentEntry;
    final previousEntryId = currentEntry?.prevEntryId;
    if (previousEntryId != null) {
      final previousEntry = _entriesById[previousEntryId];
      if (previousEntry != null) {
        _currentEntryId = previousEntry.entryId;
        return QueueCommandResult(
          queueChanged: false,
          shouldStopPlayback: false,
          trackIdToPlay: previousEntry.trackId,
        );
      }
    }

    final pendingTrackId = _pendingLibraryBackTrackId;
    if (pendingTrackId != null) {
      return rebuildFromLibraryClick(pendingTrackId);
    }

    return const QueueCommandResult.noop();
  }

  void prependTrack(String trackId) {
    final entry = QueueEntry(entryId: _nextEntryId(), trackId: trackId);
    if (_headEntryId == null) {
      _appendExistingEntry(entry);
      _currentEntryId = entry.entryId;
      return;
    }
    _insertEntryBefore(entry, _headEntryId!);
  }

  void appendTrack(String trackId) {
    final entry = QueueEntry(entryId: _nextEntryId(), trackId: trackId);
    _appendExistingEntry(entry);
    _currentEntryId ??= entry.entryId;
  }

  void insertAfterCurrent(String trackId) {
    final currentEntry = _currentEntry;
    if (currentEntry == null) {
      appendTrack(trackId);
      return;
    }

    final entry = QueueEntry(entryId: _nextEntryId(), trackId: trackId);
    _insertEntryAfter(entry, currentEntry.entryId);
  }

  QueueCommandResult removeEntry(String entryId) {
    final entry = _entriesById[entryId];
    if (entry == null) {
      return const QueueCommandResult.noop();
    }

    final wasCurrent = entry.entryId == _currentEntryId;
    final nextEntryId = entry.nextEntryId;
    _unlinkEntry(entryId);

    if (!wasCurrent) {
      return const QueueCommandResult(
        queueChanged: true,
        shouldStopPlayback: false,
      );
    }

    _currentEntryId = nextEntryId;
    if (_currentEntry == null) {
      return const QueueCommandResult(
        queueChanged: true,
        shouldStopPlayback: true,
      );
    }

    return QueueCommandResult(
      queueChanged: true,
      shouldStopPlayback: false,
      trackIdToPlay: _currentEntry!.trackId,
    );
  }

  void moveEntryBefore(String entryId, String targetEntryId) {
    if (entryId == targetEntryId) {
      return;
    }
    final entry = _entriesById[entryId];
    final target = _entriesById[targetEntryId];
    if (entry == null || target == null) {
      return;
    }

    _detachEntry(entry.entryId);
    _insertEntryBefore(entry, target.entryId);
  }

  void moveEntryAfter(String entryId, String targetEntryId) {
    if (entryId == targetEntryId) {
      return;
    }
    final entry = _entriesById[entryId];
    final target = _entriesById[targetEntryId];
    if (entry == null || target == null) {
      return;
    }

    _detachEntry(entry.entryId);
    _insertEntryAfter(entry, target.entryId);
  }

  void clear() {
    _resetQueue();
  }

  void clearUpcomingKeepingCurrent() {
    final currentEntry = _currentEntry;
    if (currentEntry == null) {
      _resetQueue();
      return;
    }

    final preservedEntry = QueueEntry(
      entryId: currentEntry.entryId,
      trackId: currentEntry.trackId,
    );

    _entriesById
      ..clear()
      ..[preservedEntry.entryId] = preservedEntry;
    _historyTrackIds.clear();
    _headEntryId = preservedEntry.entryId;
    _tailEntryId = preservedEntry.entryId;
    _currentEntryId = preservedEntry.entryId;
    _pendingLibraryBackTrackId = null;
  }

  String? findFirstEntryIdByTrackId(String trackId) {
    var entryId = _headEntryId;
    while (entryId != null) {
      final entry = _entriesById[entryId];
      if (entry == null) {
        return null;
      }
      if (entry.trackId == trackId) {
        return entry.entryId;
      }
      entryId = entry.nextEntryId;
    }
    return null;
  }

  QueueEntry? get _currentEntry {
    final currentEntryId = _currentEntryId;
    if (currentEntryId == null) {
      return null;
    }
    return _entriesById[currentEntryId];
  }

  void _resetQueue() {
    _entriesById.clear();
    _historyTrackIds.clear();
    _headEntryId = null;
    _tailEntryId = null;
    _currentEntryId = null;
    _pendingLibraryBackTrackId = null;
  }

  String _resolveTrackTitle(String trackId) {
    final track = _library.where((item) => item.id == trackId).firstOrNull;
    return track?.title ?? trackId;
  }

  String _nextEntryId() {
    _entrySequence += 1;
    return 'queue-entry-$_entrySequence';
  }

  void _appendEntry(String trackId) {
    _appendExistingEntry(QueueEntry(entryId: _nextEntryId(), trackId: trackId));
  }

  void _appendExistingEntry(QueueEntry entry) {
    final tailEntryId = _tailEntryId;
    if (tailEntryId == null) {
      _entriesById[entry.entryId] = entry;
      _headEntryId = entry.entryId;
      _tailEntryId = entry.entryId;
      return;
    }

    final tail = _entriesById[tailEntryId];
    if (tail == null) {
      _entriesById[entry.entryId] = entry;
      _headEntryId = entry.entryId;
      _tailEntryId = entry.entryId;
      return;
    }

    entry
      ..prevEntryId = tail.entryId
      ..nextEntryId = null;
    tail.nextEntryId = entry.entryId;
    _entriesById[entry.entryId] = entry;
    _tailEntryId = entry.entryId;
  }

  void _insertEntryBefore(QueueEntry entry, String targetEntryId) {
    final target = _entriesById[targetEntryId];
    if (target == null) {
      _appendExistingEntry(entry);
      return;
    }

    entry
      ..prevEntryId = target.prevEntryId
      ..nextEntryId = target.entryId;
    _entriesById[entry.entryId] = entry;

    if (target.prevEntryId != null) {
      final previous = _entriesById[target.prevEntryId!];
      previous?.nextEntryId = entry.entryId;
    } else {
      _headEntryId = entry.entryId;
    }

    target.prevEntryId = entry.entryId;
  }

  void _insertEntryAfter(QueueEntry entry, String targetEntryId) {
    final target = _entriesById[targetEntryId];
    if (target == null) {
      _appendExistingEntry(entry);
      return;
    }

    entry
      ..prevEntryId = target.entryId
      ..nextEntryId = target.nextEntryId;
    _entriesById[entry.entryId] = entry;

    if (target.nextEntryId != null) {
      final next = _entriesById[target.nextEntryId!];
      next?.prevEntryId = entry.entryId;
    } else {
      _tailEntryId = entry.entryId;
    }

    target.nextEntryId = entry.entryId;
  }

  void _unlinkEntry(String entryId) {
    _detachEntry(entryId);
    _entriesById.remove(entryId);
  }

  void _detachEntry(String entryId) {
    final entry = _entriesById[entryId];
    if (entry == null) {
      return;
    }

    final previousEntryId = entry.prevEntryId;
    final nextEntryId = entry.nextEntryId;

    if (previousEntryId != null) {
      final previous = _entriesById[previousEntryId];
      previous?.nextEntryId = nextEntryId;
    } else {
      _headEntryId = nextEntryId;
    }

    if (nextEntryId != null) {
      final next = _entriesById[nextEntryId];
      next?.prevEntryId = previousEntryId;
    } else {
      _tailEntryId = previousEntryId;
    }

    entry
      ..prevEntryId = null
      ..nextEntryId = null;
    if (_currentEntryId == entry.entryId) {
      _currentEntryId = null;
    }
  }
}
