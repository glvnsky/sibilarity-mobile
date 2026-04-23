import 'dart:convert';
import 'dart:typed_data';

class TrackMetadata {
  const TrackMetadata({
    required this.trackId,
    required this.source,
    required this.found,
    this.title,
    this.artist,
    this.album,
    this.year,
    this.genre,
    this.trackNumber,
    this.duration,
    this.bitrate,
    this.sampleRate,
    this.channels,
    this.coverDataUrl,
    this.coverUrl,
    this.coverBytes,
  });

  factory TrackMetadata.fromJson(Map<String, dynamic> json) {
    Uint8List? decodedCoverBytes;
    final rawCoverData = json['cover_data_url']?.toString();
    if (rawCoverData != null && rawCoverData.isNotEmpty) {
      final comma = rawCoverData.indexOf(',');
      if (comma >= 0 && comma + 1 < rawCoverData.length) {
        try {
          decodedCoverBytes = base64Decode(rawCoverData.substring(comma + 1));
        } catch (_) {
          decodedCoverBytes = null;
        }
      }
    }

    return TrackMetadata(
      trackId: json['track_id']?.toString() ?? '',
      source: json['source']?.toString() ?? 'unknown',
      found: json['found'] == true,
      title: json['title']?.toString(),
      artist: json['artist']?.toString(),
      album: json['album']?.toString(),
      year: json['year'] is num ? (json['year'] as num).toInt() : null,
      genre: json['genre']?.toString(),
      trackNumber: json['track_number'] is num ? (json['track_number'] as num).toInt() : null,
      duration: json['duration'] is num ? (json['duration'] as num).toDouble() : null,
      bitrate: json['bitrate'] is num ? (json['bitrate'] as num).toInt() : null,
      sampleRate: json['sample_rate'] is num ? (json['sample_rate'] as num).toInt() : null,
      channels: json['channels'] is num ? (json['channels'] as num).toInt() : null,
      coverDataUrl: json['cover_data_url']?.toString(),
      coverUrl: json['cover_url']?.toString(),
      coverBytes: decodedCoverBytes,
    );
  }

  final String trackId;
  final String source;
  final bool found;
  final String? title;
  final String? artist;
  final String? album;
  final int? year;
  final String? genre;
  final int? trackNumber;
  final double? duration;
  final int? bitrate;
  final int? sampleRate;
  final int? channels;
  final String? coverDataUrl;
  final String? coverUrl;
  final Uint8List? coverBytes;
}
