import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'hub_mode_types.dart';

export 'hub_mode_types.dart';

/// Reads one string property, tolerating a missing or non-string value: the
/// injected object comes from the page, and a half-written one must degrade
/// rather than crash the app before it can say why.
String? _string(JSObject? owner, String key) {
  final value = owner?.getProperty<JSAny?>(key.toJS);
  return value.isA<JSString>() ? (value! as JSString).toDart : null;
}

JSObject? _object(String key) {
  final value = globalContext.getProperty<JSAny?>(key.toJS);
  return value.isA<JSObject>() ? value! as JSObject : null;
}

/// Null on `app.frelocator.riumu.net`: the public build has no such global,
/// so it stays on `PrefsStateStore` exactly as before.
HubMode? readHubMode() {
  final hub = _object('__FRELOCATOR_HUB__');
  if (hub == null) return null;
  final base = _string(hub, 'base');
  final api = _string(hub, 'api');
  if (base == null || api == null) return null;
  final schema = hub.getProperty<JSAny?>('schema'.toJS);
  return HubMode(
    base: base,
    api: api,
    hubDeviceId: _string(hub, 'hubDeviceId') ?? 'hub',
    dataFile: _string(hub, 'dataFile') ?? '',
    schema: schema.isA<JSNumber>() ? (schema! as JSNumber).toDartInt : 2,
  );
}

const _webIdKey = 'frelocator.webId';

/// The only thing this browser persists. Business data deliberately stays in
/// memory: two copies of the truth would turn every reload into a three-way
/// merge against whatever MCP did while the tab was closed.
String? readWebId() {
  final storage = _object('localStorage');
  if (storage == null) return null;
  // Private-mode Safari throws from localStorage rather than returning null.
  try {
    final value = storage.callMethod<JSAny?>('getItem'.toJS, _webIdKey.toJS);
    return value.isA<JSString>() ? (value! as JSString).toDart : null;
  } catch (_) {
    return null;
  }
}

void saveWebId(String id) {
  final storage = _object('localStorage');
  if (storage == null) return;
  try {
    storage.callMethod<JSAny?>('setItem'.toJS, _webIdKey.toJS, id.toJS);
  } catch (_) {
    // A browser that refuses storage still works; it just looks like a new
    // client to the hub after every reload.
  }
}

/// The id survives reloads so `sync_status.webClients` does not grow one entry
/// per refresh; a browser that cannot store it simply gets a fresh one.
String ensureWebId() {
  final existing = readWebId();
  if (existing != null && RegExp(r'^[0-9a-f]{16}$').hasMatch(existing)) return existing;
  final minted = randomWebId();
  saveWebId(minted);
  return minted;
}

String? readOrigin() => _string(_object('location'), 'origin');

bool documentVisible() => _string(_object('document'), 'visibilityState') != 'hidden';

/// Polling stops while the tab is hidden: a background tab holding a 2 s poll
/// open is pure noise on the hub and in the network log.
void addVisibilityListener(void Function(bool visible) listener) {
  final document = _object('document');
  if (document == null) return;
  document.callMethod<JSAny?>(
    'addEventListener'.toJS,
    'visibilitychange'.toJS,
    ((JSAny? _) => listener(documentVisible())).toJS,
  );
}

/// Hub mode keeps no copy of the document in the browser, so a reload with an
/// unsent edit loses it. The guard is the only thing standing between the user
/// and that loss.
void setUnloadGuard(bool Function() hasUnsentEdits) {
  globalContext.callMethod<JSAny?>(
    'addEventListener'.toJS,
    'beforeunload'.toJS,
    ((JSObject event) {
      if (!hasUnsentEdits()) return;
      event.callMethod<JSAny?>('preventDefault'.toJS);
      // Legacy spelling; some browsers still need a non-empty returnValue.
      event.setProperty('returnValue'.toJS, ''.toJS);
    }).toJS,
  );
}
