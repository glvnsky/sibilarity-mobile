class QueueEntry {
  QueueEntry({
    required this.entryId,
    required this.trackId,
    this.prevEntryId,
    this.nextEntryId,
  });

  final String entryId;
  final String trackId;
  String? prevEntryId;
  String? nextEntryId;
}
