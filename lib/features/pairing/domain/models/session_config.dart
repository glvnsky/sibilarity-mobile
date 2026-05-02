class SessionConfig {
  const SessionConfig({
    required this.baseUrl,
    required this.accessToken,
    required this.refreshToken,
    required this.deviceId,
  });

  final String baseUrl;
  final String accessToken;
  final String refreshToken;
  final String deviceId;

  SessionConfig copyWith({
    String? baseUrl,
    String? accessToken,
    String? refreshToken,
    String? deviceId,
  }) => SessionConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    deviceId: deviceId ?? this.deviceId,
  );
}
