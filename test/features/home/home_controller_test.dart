import 'package:flutter_test/flutter_test.dart';
import 'package:music_remote_app/core/models/track_item.dart';
import 'package:music_remote_app/core/models/track_metadata.dart';
import 'package:music_remote_app/core/network/music_api.dart';
import 'package:music_remote_app/features/home/application/home_controller.dart';
import 'package:music_remote_app/features/home/application/home_state.dart';
import 'package:music_remote_app/features/library/application/library_coordinator.dart';
import 'package:music_remote_app/features/playback_queue/application/playback_session_service.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_service.dart';
import 'package:music_remote_app/features/playback_queue/domain/playback_queue_snapshot.dart';

class _RecordingMusicApi extends MusicApi {
  final List<({String endpoint, Map<String, dynamic>? body})> commands =
      <({String endpoint, Map<String, dynamic>? body})>[];

  @override
  Future<void> command(String endpoint, {Map<String, dynamic>? body}) async {
    commands.add((endpoint: endpoint, body: body));
  }
}

void main() {
  group('HomeController', () {
    test('syncQueueState updates queue snapshot and selected track', () {
      final controller = HomeController();
      const snapshot = PlaybackQueueSnapshot(
        items: <PlaybackQueueSnapshotItem>[
          PlaybackQueueSnapshotItem(
            entryId: 'entry-1',
            trackId: 'track-1',
            title: 'Track 1',
            isCurrent: true,
          ),
        ],
        currentEntryId: 'entry-1',
        currentTrackId: 'track-1',
        pendingLibraryBackTrackId: null,
        historyLength: 0,
        canGoNext: false,
        canGoPrev: false,
        isEmpty: false,
      );

      controller.syncQueueState(snapshot);

      expect(controller.state.playback.queueSnapshot.currentTrackId, 'track-1');
      expect(controller.state.library.selectedTrackId, 'track-1');
    });

    test('applyRemoteState updates playback fields and returns side effects', () {
      final controller = HomeController(
        initialState: const RemoteHomeState(
          connection: HomeConnectionState(statusText: 'Paused'),
          playback: HomePlaybackState(
            volume: 10,
            position: 12,
            duration: 30,
            currentTrack: 'Old Track',
            currentTrackId: 'old-track',
          ),
        ),
      );

      final result = controller.applyRemoteState(
        <String, dynamic>{
          'volume': 44,
          'shuffle': true,
          'repeat_mode': 'all',
          'status': 'playing',
          'current_track_id': 'track-2',
          'position': 15,
          'duration': 120,
        },
        systemVolumeSupported: true,
        resolveTrackTitle: (trackId) => 'Resolved $trackId',
      );

      expect(result.changed, isTrue);
      expect(result.trackChanged, isTrue);
      expect(result.shouldSyncSystemVolume, isTrue);
      expect(controller.state.connection.statusText, 'playing');
      expect(controller.state.playback.volume, 44);
      expect(controller.state.playback.shuffle, isTrue);
      expect(controller.state.playback.repeatMode, 'all');
      expect(controller.state.playback.position, 15);
      expect(controller.state.playback.duration, 120);
      expect(controller.state.playback.currentTrackId, 'track-2');
      expect(controller.state.playback.currentTrack, 'Resolved track-2');
      expect(controller.state.library.selectedTrackId, 'track-2');
    });

    test('applyRemoteState preserves stopped seek position when stopped', () {
      final controller = HomeController(
        initialState: const RemoteHomeState(
          connection: HomeConnectionState(statusText: 'stopped'),
          playback: HomePlaybackState(
            position: 10,
            duration: 100,
            stoppedSeekPosition: 42,
          ),
        ),
      )..applyRemoteState(
          <String, dynamic>{
            'status': 'stopped',
            'position': 80,
            'duration': 100,
          },
          systemVolumeSupported: false,
          resolveTrackTitle: (trackId) => trackId,
        );

      expect(controller.state.playback.position, 42);
      expect(controller.state.playback.stoppedSeekPosition, 42);
    });

    test('resetAfterDisconnect clears transient state and preserves device id', () {
      final controller = HomeController(
        initialState: const RemoteHomeState(
          tabIndex: 2,
          connection: HomeConnectionState(
            busy: true,
            backgroundSyncing: true,
            commandBusy: true,
            serverHealthy: true,
            statusText: 'Connected',
            commandStatus: 'Busy',
            lastError: 'Boom',
          ),
          pairing: HomePairingState(
            discovering: true,
            pairing: true,
            deviceId: 'device-1',
            refreshToken: 'refresh-1',
          ),
          playback: HomePlaybackState(
            volume: 99,
            currentTrack: 'Track',
            currentTrackId: 'track-1',
          ),
          library: HomeLibraryState(
            selectedTrackId: 'track-1',
            uploading: true,
            uploadProgress: 0.6,
          ),
          metadata: HomeMetadataState(
            loading: true,
          ),
        ),
      )..resetAfterDisconnect();

      expect(controller.state.tabIndex, 0);
      expect(controller.state.connection.statusText, 'Disconnected');
      expect(controller.state.connection.commandStatus, 'Session revoked');
      expect(controller.state.connection.serverHealthy, isFalse);
      expect(controller.state.pairing.deviceId, 'device-1');
      expect(controller.state.pairing.refreshToken, isEmpty);
      expect(controller.state.playback.currentTrackId, isNull);
      expect(controller.state.library.selectedTrackId, isNull);
      expect(controller.state.metadata.currentMetadata, isNull);
      expect(controller.state.metadata.loading, isFalse);
    });

    test('playTrack updates queue state and command status', () async {
      final api = _RecordingMusicApi();
      final session = PlaybackSessionService(
        api: api,
        queueService: PlaybackQueueService(),
      )..setLibrary(const <TrackItem>[
          TrackItem(id: 'a', title: 'A'),
          TrackItem(id: 'b', title: 'B'),
        ]);
      final controller = HomeController(playbackSession: session);

      await controller.playTrack(const TrackItem(id: 'b', title: 'B'));

      expect(controller.state.connection.commandBusy, isFalse);
      expect(controller.state.connection.commandStatus, 'Done');
      expect(controller.state.library.selectedTrackId, 'b');
      expect(controller.state.playback.queueSnapshot.currentTrackId, 'b');
      expect(
        controller.state.playback.queueSnapshot.items.map((item) => item.trackId),
        <String>['b'],
      );
      expect(api.commands.single.endpoint, '/api/play');
      expect(api.commands.single.body, <String, dynamic>{'track_id': 'b'});
    });

    test('playCurrentQueueTrack seeks to stored stopped position', () async {
      final api = _RecordingMusicApi();
      final session = PlaybackSessionService(
        api: api,
        queueService: PlaybackQueueService(),
      )..setLibrary(const <TrackItem>[
          TrackItem(id: 'a', title: 'A'),
          TrackItem(id: 'b', title: 'B'),
        ]);
      final controller = HomeController(
        playbackSession: session,
        initialState: const RemoteHomeState(
          connection: HomeConnectionState(statusText: 'stopped'),
          playback: HomePlaybackState(stoppedSeekPosition: 33),
          library: HomeLibraryState(
            items: <TrackItem>[
              TrackItem(id: 'a', title: 'A'),
              TrackItem(id: 'b', title: 'B'),
            ],
          ),
        ),
      );
      var seekPosition = -1.0;

      await controller.playCurrentQueueTrack(
        seekPlaybackPosition: (position) async {
          seekPosition = position;
        },
      );

      expect(seekPosition, 33);
      expect(controller.state.playback.queueSnapshot.currentTrackId, 'a');
      expect(api.commands.single.endpoint, '/api/play');
      expect(api.commands.single.body, <String, dynamic>{'track_id': 'a'});
    });

    test('addTrackToQueueEnd and reorderQueueEntry update snapshot locally', () {
      final api = _RecordingMusicApi();
      final session = PlaybackSessionService(
        api: api,
        queueService: PlaybackQueueService(),
      );
      final controller = HomeController(playbackSession: session)
        ..addTrackToQueueEnd(const TrackItem(id: 'a', title: 'A'))
        ..addTrackToQueueEnd(const TrackItem(id: 'b', title: 'B'))
        ..reorderQueueEntry(0, 2);

      expect(controller.state.connection.commandStatus, 'Queue reordered');
      expect(
        controller.state.playback.queueSnapshot.items.map((item) => item.trackId),
        <String>['b', 'a'],
      );
      expect(api.commands, isEmpty);
    });

    test('applyLibraryRefreshResult updates library items and selected track', () {
      final controller = HomeController();

      // ignore: cascade_invocations
      controller.applyLibraryRefreshResult(
        const LibraryRefreshResult(
          library: <TrackItem>[
            TrackItem(id: 'a', title: 'A'),
            TrackItem(id: 'b', title: 'B'),
          ],
          selectedTrackId: 'b',
        ),
      );

      expect(controller.state.library.items, hasLength(2));
      expect(controller.state.library.selectedTrackId, 'b');
    });

    test('metadata helpers manage loading and active metadata state', () {
      final controller = HomeController(
        initialState: const RemoteHomeState(
          playback: HomePlaybackState(currentTrackId: 'track-1'),
          library: HomeLibraryState(selectedTrackId: 'track-1'),
        ),
      );

      // ignore: cascade_invocations
      controller.startMetadataLoading();
      expect(controller.state.metadata.loading, isTrue);

      controller.applyMetadataRefreshResult(
        const MetadataRefreshResult(
          kind: MetadataRefreshKind.fetched,
          trackId: 'track-1',
          metadata: TrackMetadata(
            trackId: 'track-1',
            source: 'taglib',
            found: true,
            title: 'Track 1',
          ),
        ),
      );

      expect(controller.state.metadata.loading, isFalse);
      expect(controller.state.metadata.currentMetadata?.title, 'Track 1');

      // ignore: cascade_invocations
      controller.startMetadataLoading();
      // ignore: cascade_invocations
      controller.applyMetadataRefreshResult(
        const MetadataRefreshResult.cleared(),
      );

      expect(controller.state.metadata.loading, isFalse);
      expect(controller.state.metadata.currentMetadata, isNull);
    });

    test('upload helpers manage upload state and progress', () {
      final controller = HomeController();

      // ignore: cascade_invocations
      controller.startUpload();
      expect(controller.state.library.uploading, isTrue);
      expect(controller.state.library.uploadProgress, 0);

      controller.updateUploadProgress(0.42);
      expect(controller.state.library.uploadProgress, 0.42);

      controller.finishUpload();
      expect(controller.state.library.uploading, isFalse);
    });
  });
}
