import 'package:flutter/material.dart';
import 'package:music_remote_app/features/pairing/domain/models/discovered_server.dart';

class ConnectTab extends StatelessWidget {
  const ConnectTab({
    required this.serverHealthy,
    required this.statusText,
    required this.selectedServer,
    required this.isPaired,
    required this.busy,
    required this.backgroundSyncing,
    required this.pairing,
    required this.discovering,
    required this.discoveredServers,
    required this.lastError,
    required this.initializing,
    required this.onDisconnect,
    required this.onPairAndConnect,
    required this.onDiscoverServers,
    required this.onRefreshState,
    required this.onSelectServer,
    super.key,
  });

  final bool serverHealthy;
  final String statusText;
  final String selectedServer;
  final bool isPaired;
  final bool busy;
  final bool backgroundSyncing;
  final bool pairing;
  final bool discovering;
  final List<DiscoveredServer> discoveredServers;
  final String lastError;
  final bool initializing;
  final Future<void> Function() onDisconnect;
  final Future<void> Function() onPairAndConnect;
  final Future<void> Function() onDiscoverServers;
  final Future<void> Function() onRefreshState;
  final ValueChanged<String> onSelectServer;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  serverHealthy ? Icons.cloud_done : Icons.cloud_off,
                  color: serverHealthy ? colors.primary : colors.error,
                ),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns),
              title: const Text('Selected server'),
              subtitle: Text(
                selectedServer.isEmpty ? 'Not selected yet' : selectedServer,
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.phonelink_lock),
              title: const Text('Pairing status'),
              subtitle: Text(isPaired ? 'Paired' : 'Not paired'),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: (busy || backgroundSyncing) ? null : onDisconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Disconnect'),
                ),
                FilledButton.tonalIcon(
                  onPressed: pairing ? null : onPairAndConnect,
                  icon: const Icon(Icons.phonelink_lock),
                  label: Text(pairing ? 'Pairing...' : 'Pair & Connect'),
                ),
                OutlinedButton.icon(
                  onPressed: discovering ? null : onDiscoverServers,
                  icon: const Icon(Icons.travel_explore),
                  label: Text(discovering ? 'Discovering...' : 'Discover'),
                ),
                OutlinedButton.icon(
                  onPressed: onRefreshState,
                  icon: const Icon(Icons.update),
                  label: const Text('State'),
                ),
              ],
            ),
            if (discoveredServers.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Discovered servers',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              ...discoveredServers.map(
                (server) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.speaker_group),
                  title: Text(server.name),
                  subtitle: Text(server.baseUrl),
                  trailing: OutlinedButton(
                    onPressed: () => onSelectServer(server.baseUrl),
                    child: const Text('Select'),
                  ),
                ),
              ),
            ],
            if (lastError.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(lastError, style: TextStyle(color: colors.error)),
            ],
            if (initializing || backgroundSyncing) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
              const SizedBox(height: 6),
              Text(
                initializing ? 'Initializing...' : 'Syncing in background...',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
