class PairingStartResult {
  const PairingStartResult({required this.pairingId});

  final String pairingId;
}

class PairingConfirmResult {
  const PairingConfirmResult({
    required this.accessToken,
    required this.refreshToken,
  });

  final String accessToken;
  final String refreshToken;
}
