import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import 'package:music_remote_app/features/pairing/domain/models/discovered_server.dart';

class PairingDiscoveryService {
  static const _defaultPort = 8000;

  Future<List<DiscoveredServer>> discoverServers() async {
    final mdnsDiscovered = await _discoverViaMdns();
    if (mdnsDiscovered.isNotEmpty) {
      return _rankByReachability(mdnsDiscovered);
    }

    final subnetDiscovered = await _discoverViaSubnetScan();
    if (subnetDiscovered.isNotEmpty) {
      return _rankByReachability(subnetDiscovered);
    }

    return const [];
  }

  Future<List<DiscoveredServer>> _discoverViaMdns() async {
    final mdns = MDnsClient(
      // Some Android builds fail with "reusePort not supported".
      rawDatagramSocketFactory: (
        dynamic host,
        int port, {
        bool reuseAddress = true,
        bool reusePort = false,
        int ttl = 1,
      }) => RawDatagramSocket.bind(
        host,
        port,
        reuseAddress: reuseAddress,
        ttl: ttl,
      ),
    );
    final discovered = <DiscoveredServer>{};

    try {
      await mdns.start();
      final ptrRecords = <PtrResourceRecord>[];
      for (final serviceName in const ['_sibilarity._tcp.local', '_sibilarity._tcp']) {
        final records = await mdns
            .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(serviceName),
            )
            .take(20)
            .timeout(
              const Duration(seconds: 4),
              onTimeout: (sink) => sink.close(),
            )
            .toList();
        ptrRecords.addAll(records);
      }

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
          if (host.isEmpty || host.contains(':')) {
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

      return discovered.toList();
    } finally {
      mdns.stop();
    }
  }

  Future<List<DiscoveredServer>> _discoverViaSubnetScan() async {
    final prefixes = await _localPrivatePrefixes();
    if (prefixes.isEmpty) {
      return const [];
    }

    final results = <DiscoveredServer>[];
    for (final prefix in prefixes) {
      results.addAll(await _scanPrefix(prefix));
    }
    return results;
  }

  Future<List<String>> _localPrivatePrefixes() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final prefixes = <String>{};

    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final ip = address.address;
        if (!_isPrivateIpv4(ip)) {
          continue;
        }
        final octets = ip.split('.');
        if (octets.length != 4) {
          continue;
        }
        prefixes.add('${octets[0]}.${octets[1]}.${octets[2]}');
      }
    }

    return prefixes.toList();
  }

  bool _isPrivateIpv4(String ip) {
    final octets = ip.split('.');
    if (octets.length != 4) {
      return false;
    }
    final first = int.tryParse(octets[0]);
    final second = int.tryParse(octets[1]);
    if (first == null || second == null) {
      return false;
    }
    if (first == 10) {
      return true;
    }
    if (first == 192 && second == 168) {
      return true;
    }
    if (first == 172 && second >= 16 && second <= 31) {
      return true;
    }
    return false;
  }

  Future<List<DiscoveredServer>> _scanPrefix(String prefix) async {
    var nextHost = 1;
    final found = <DiscoveredServer>[];

    Future<void> worker() async {
      while (true) {
        final hostPart = nextHost;
        nextHost += 1;
        if (hostPart > 254) {
          return;
        }

        final host = '$prefix.$hostPart';
        final reachable = await _isLikelySibilarityServer(host, _defaultPort);
        if (!reachable) {
          continue;
        }
        found.add(
          DiscoveredServer(
            name: 'Sibilarity ($host)',
            host: host,
            port: _defaultPort,
          ),
        );
      }
    }

    await Future.wait(List<Future<void>>.generate(24, (_) => worker()));
    return found;
  }

  Future<List<DiscoveredServer>> _rankByReachability(List<DiscoveredServer> servers) async {
    if (servers.isEmpty) {
      return const [];
    }

    final ranked = <({DiscoveredServer server, int score})>[];
    for (final server in servers) {
      final score = await _serverScore(server);
      ranked.add((server: server, score: score));
    }

    ranked.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return a.server.name.compareTo(b.server.name);
    });

    return ranked.map((entry) => entry.server).toList();
  }

  Future<int> _serverScore(DiscoveredServer server) async {
    if (await _isLikelySibilarityServer(server.host, server.port)) {
      return 2;
    }
    if (await _isTcpOpen(server.host, server.port)) {
      return 1;
    }
    return 0;
  }

  Future<bool> _isLikelySibilarityServer(String host, int port) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 700);
    try {
      final uri = Uri.parse('http://$host:$port/openapi.json');
      final request = await client.getUrl(uri).timeout(const Duration(milliseconds: 700));
      final response = await request.close().timeout(const Duration(milliseconds: 900));
      if (response.statusCode != 200) {
        return await _isTcpOpen(host, port);
      }
      final body = await utf8.decodeStream(response).timeout(const Duration(milliseconds: 900));
      return body.contains('/api/state') || body.toLowerCase().contains('sibilarity');
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _isTcpOpen(String host, int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: const Duration(milliseconds: 450));
      return true;
    } catch (_) {
      return false;
    } finally {
      await socket?.close();
    }
  }
}
