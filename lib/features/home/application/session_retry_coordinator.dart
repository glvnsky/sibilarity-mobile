class SessionRetryCoordinator {
  SessionRetryCoordinator({
    required Future<bool> Function() refreshSession,
    required Future<void> Function({String message}) markSessionExpired,
    required bool Function(Object error) isUnauthorizedError,
  }) : _refreshSession = refreshSession,
       _markSessionExpired = markSessionExpired,
       _isUnauthorizedError = isUnauthorizedError;

  final Future<bool> Function() _refreshSession;
  final Future<void> Function({String message}) _markSessionExpired;
  final bool Function(Object error) _isUnauthorizedError;

  Future<T?> run<T>({
    required Future<T> Function() action,
    Future<T> Function()? retryAction,
    String sessionExpiredMessage = 'Session expired. Pair again.',
  }) async {
    try {
      return await action();
    } catch (error) {
      if (!_isUnauthorizedError(error)) {
        rethrow;
      }
      final refreshed = await _refreshSession();
      if (refreshed) {
        return await (retryAction ?? action)();
      }
      await _markSessionExpired(message: sessionExpiredMessage);
      return null;
    }
  }
}
