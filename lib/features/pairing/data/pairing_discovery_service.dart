import 'package:multicast_dns/multicast_dns.dart';

import 'package:music_remote_app/features/pairing/domain/models/discovered_server.dart';

class PairingDiscoveryService {
  Future<List<DiscoveredServer>> discoverServers() async {
    final mdns = MDnsClient();
    final discovered = <DiscoveredServer>{};
    try {
      await mdns.start();
      final ptrRecords = await mdns
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer('_sibilarity._tcp.local'),
          )
          .take(20)
          .timeout(
            const Duration(seconds: 4),
            onTimeout: (sink) => sink.close(),
          )
          .toList();

      for (final ptr in ptrRecords) {
        final srvRecords = await mdns
            .lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(ptr.domainName),
            )
            .take(2)
            .timeout(
              const Duration(seconds: 2),
              onTimeout: (sink) => sink.close(),
            )
            .toList();
        for (final srv in srvRecords) {
          final hostRecords = await mdns
              .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
              )
              .take(2)
              .timeout(
                const Duration(seconds: 2),
                onTimeout: (sink) => sink.close(),
              )
              .toList();
          final host = hostRecords.isNotEmpty
              ? hostRecords.first.address.address
              : srv.target.replaceFirst(RegExp(r'\.$'), '');
          if (host.isEmpty) {
            continue;
          }
          final deviceName = ptr.domainName.split('._sibilarity').first;
          discovered.add(
            DiscoveredServer(
              name: deviceName.isEmpty ? host : deviceName,
              host: host,
              port: srv.port,
            ),
          );
        }
      }

      final sorted = discovered.toList()..sort((a, b) => a.name.compareTo(b.name));
      return sorted;
    } finally {
      mdns.stop();
    }
  }
}
