import 'package:flutter_test/flutter_test.dart';
import 'package:music_remote_app/features/home/application/session_retry_coordinator.dart';

void main() {
  group('SessionRetryCoordinator', () {
    test('returns action result when no error occurs', () async {
      final coordinator = SessionRetryCoordinator(
        refreshSession: () async => false,
        markSessionExpired: ({String message = ''}) async {},
        isUnauthorizedError: (_) => false,
      );

      final result = await coordinator.run<String>(
        action: () async => 'ok',
      );

      expect(result, 'ok');
    });

    test('refreshes session and retries once on unauthorized error', () async {
      var attempts = 0;
      var refreshCalls = 0;
      final coordinator = SessionRetryCoordinator(
        refreshSession: () async {
          refreshCalls += 1;
          return true;
        },
        markSessionExpired: ({String message = ''}) async {},
        isUnauthorizedError: (error) => error.toString().contains('401'),
      );

      final result = await coordinator.run<String>(
        action: () async {
          attempts += 1;
          if (attempts == 1) {
            throw Exception('401 Unauthorized');
          }
          return 'retried';
        },
      );

      expect(refreshCalls, 1);
      expect(attempts, 2);
      expect(result, 'retried');
    });

    test('marks session expired and returns null when refresh fails', () async {
      var expiredMessage = '';
      final coordinator = SessionRetryCoordinator(
        refreshSession: () async => false,
        markSessionExpired: ({String message = ''}) async {
          expiredMessage = message;
        },
        isUnauthorizedError: (error) => error.toString().contains('401'),
      );

      final result = await coordinator.run<String>(
        action: () async => throw Exception('401 Unauthorized'),
        sessionExpiredMessage: 'Pair again',
      );

      expect(result, isNull);
      expect(expiredMessage, 'Pair again');
    });

    test('rethrows non-unauthorized errors', () async {
      final coordinator = SessionRetryCoordinator(
        refreshSession: () async => false,
        markSessionExpired: ({String message = ''}) async {},
        isUnauthorizedError: (_) => false,
      );

      expect(
        () => coordinator.run<void>(
          action: () async => throw StateError('boom'),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
