/// Where the hub answers: an IPv4 address and the port it listens on.
typedef HubAddress = ({String host, int port});

/// Web fallback: a browser cannot open a multicast socket, so there is nothing
/// to discover and the manual address stays the only path.
Future<HubAddress?> discoverHub({Duration timeout = const Duration(seconds: 3)}) async => null;
