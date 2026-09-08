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
  final client = MDnsClient();
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
