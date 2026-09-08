import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

/// Where the hub answers: an IPv4 address and the port it listens on.
typedef HubAddress = ({String host, int port});

/// Looks for `_frelocator._tcp` on the local network.
///
/// Every failure — no responder, a firewall that eats multicast, a platform
/// that refuses the socket — is answered with `null` rather than an exception:
/// discovery is only ever a convenience behind the address the user already
/// typed or scanned, so it must not turn a working manual setup into an error.
/// The whole lookup is bounded by [timeout].
Future<HubAddress?> discoverHub({Duration timeout = const Duration(seconds: 3)}) async {
  // Android refuses `reusePort`, and the package's default socket factory asks
  // for it: without this override every lookup dies at `bind` and discovery is
  // silently dead on the one platform that ships in the Play release. The
  // ttl of 1 keeps the query on the local link, which is all mDNS needs.
  final client = MDnsClient(
    rawDatagramSocketFactory:
        (dynamic host, int port, {bool? reuseAddress, bool? reusePort, int? ttl}) =>
            RawDatagramSocket.bind(
              host,
              port,
              reuseAddress: true,
              reusePort: false,
              ttl: ttl ?? 1,
            ),
  );
  try {
    await client.start();
    await for (final ptr in client
        .lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer('_frelocator._tcp.local'),
        )
        .timeout(timeout, onTimeout: (sink) => sink.close())) {
      await for (final srv in client
          .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
          .timeout(timeout, onTimeout: (sink) => sink.close())) {
        await for (final ip in client
            .lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target),
            )
            .timeout(timeout, onTimeout: (sink) => sink.close())) {
          return (host: ip.address.address, port: srv.port);
        }
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.stop();
  }
}
