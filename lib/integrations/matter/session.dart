import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'crypto.dart';
import 'message.dart';
import 'tlv.dart';

/// Sessions, exchanges and reliable delivery over UDP (Core spec 4.5-4.12).

class MatterException implements Exception {
  MatterException(this.message);
  final String message;
  @override
  String toString() => message;
}

class MatterTimeoutException extends MatterException {
  MatterTimeoutException([super.message = 'The device did not answer.']);
}

class SessionClosedException extends MatterException {
  SessionClosedException([super.message = 'The connection to the device was closed.']);
}

/// Set to print what goes over the wire (for debugging with real devices).
void Function(String line)? matterLog;

/// A random operational node id (Core spec 2.5.5): 1 .. 0xFFFFFFEFFFFFFFFF.
int randomOperationalNodeId() {
  while (true) {
    final v = beToInt(randomBytes(8));
    if (v != 0 && (v >>> 32) < 0xFFFFFFF0) return v;
  }
}

/// How quickly a peer wants retransmissions (its session parameters, in ms).
class MrpParams {
  const MrpParams({this.idleMs = 500, this.activeMs = 300, this.activeThresholdMs = 4000});
  final int idleMs;
  final int activeMs;
  final int activeThresholdMs;

  /// From the session parameter struct of PBKDFParamResponse / Sigma2.
  factory MrpParams.fromTlv(Object? params, [MrpParams fallback = const MrpParams()]) {
    if (params is! TlvStruct) return fallback;
    return MrpParams(
      idleMs: params.integer(1) ?? fallback.idleMs,
      activeMs: params.integer(2) ?? fallback.activeMs,
      activeThresholdMs: params.integer(3) ?? fallback.activeThresholdMs,
    );
  }

  /// From the SII / SAI / SAT keys of an mDNS TXT record.
  factory MrpParams.fromTxt(Map<String, String> txt) => MrpParams(
        idleMs: int.tryParse(txt['SII'] ?? '') ?? 500,
        activeMs: int.tryParse(txt['SAI'] ?? '') ?? 300,
        activeThresholdMs: int.tryParse(txt['SAT'] ?? '') ?? 4000,
      );

  Map<String, int> toJson() => {'sii': idleMs, 'sai': activeMs, 'sat': activeThresholdMs};

  @override
  String toString() => 'MRP(idle ${idleMs}ms, active ${activeMs}ms, threshold ${activeThresholdMs}ms)';
}

/// What this app advertises about itself in PASE and CASE.
const localMrp = MrpParams();

/// Writes our session parameters (PBKDFParamRequest field 5, Sigma1 field 5).
void writeSessionParams(TlvWriter w, int tag) => w.struct(tag, (w) {
      w.uint(1, localMrp.idleMs);
      w.uint(2, localMrp.activeMs);
      w.uint(3, localMrp.activeThresholdMs);
      w.uint(4, 17); // data model revision (Matter 1.2)
      w.uint(5, imRevision);
      w.uint(6, 0x01020000); // specification version
      w.uint(7, 1); // max paths per invoke
    });

/// Interaction model revision sent in every IM message (Matter 1.2).
const imRevision = 11;

/// Remembers which message counters were seen, to drop duplicates.
class CounterWindow {
  int? _max;
  int _bits = 0;

  /// Returns true the first time a counter is seen.
  bool accept(int counter) {
    final max = _max;
    if (max == null) {
      _max = counter;
      _bits = 0;
      return true;
    }
    final delta = (counter - max) & 0xffffffff;
    if (delta == 0) return false;
    if (delta < 0x80000000) {
      // Ahead of everything seen so far.
      _bits = delta >= 32 ? 0 : ((_bits << delta) | (1 << (delta - 1))) & 0xffffffff;
      _max = counter;
      return true;
    }
    final behind = (max - counter) & 0xffffffff;
    if (behind > 32) return false;
    final bit = 1 << (behind - 1);
    if (_bits & bit != 0) return false;
    _bits |= bit;
    return true;
  }
}

/// A received message.
class MatterMessage {
  MatterMessage(this.packet, this.header, this.payload);
  final PacketHeader packet;
  final PayloadHeader header;
  final Uint8List payload;

  int get protocolId => header.protocolId;
  int get opcode => header.opcode;

  bool get isStatusReport => protocolId == Protocols.secureChannel && opcode == SecureOp.statusReport;

  StatusReport get statusReport => StatusReport.decode(payload);
}

/// The UDP sockets every Matter conversation of the app goes through, and the
/// sessions running over them.
class MatterTransport {
  MatterTransport._(this._v4, this._v6) {
    _v4?.listen((e) => _read(_v4, e));
    _v6?.listen((e) => _read(_v6, e));
  }

  static Future<MatterTransport> open() async {
    RawDatagramSocket? v4, v6;
    try {
      v4 = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    } catch (_) {}
    try {
      v6 = await RawDatagramSocket.bind(InternetAddress.anyIPv6, 0);
    } catch (_) {}
    if (v4 == null && v6 == null) throw MatterException('The network is not available.');
    return MatterTransport._(v4, v6);
  }

  final RawDatagramSocket? _v4;
  final RawDatagramSocket? _v6;
  final _secure = <int, SecureSession>{};
  final _unsecured = <int, UnsecuredSession>{};
  bool _closed = false;

  bool get hasIpv6 => _v6 != null;

  bool supports(InternetAddress a) => a.type == InternetAddressType.IPv4 ? _v4 != null : _v6 != null;

  /// A plain session to start PASE or CASE with the device at [address].
  UnsecuredSession unsecured(InternetAddress address, int port, {MrpParams params = const MrpParams()}) {
    if (_closed) throw MatterException('Matter is shut down.');
    final s = UnsecuredSession._(this, address, port, params);
    _unsecured[s.ephemeralNodeId] = s;
    return s;
  }

  /// A local session id that is not in use (never 0).
  int newSessionId() {
    while (true) {
      final id = randomIn(1, 0xffff);
      if (!_secure.containsKey(id)) return id;
    }
  }

  void _add(SecureSession s) {
    if (_closed) throw MatterException('Matter is shut down.');
    _secure[s.localId] = s;
  }

  void _remove(Session s) {
    if (s is SecureSession && identical(_secure[s.localId], s)) _secure.remove(s.localId);
    if (s is UnsecuredSession && identical(_unsecured[s.ephemeralNodeId], s)) _unsecured.remove(s.ephemeralNodeId);
  }

  void _send(InternetAddress to, int port, List<int> data) {
    matterLog?.call('send ${data.length} bytes to ${to.address}:$port');
    if (_closed) return;
    final s = to.type == InternetAddressType.IPv4 ? _v4 : _v6;
    try {
      s?.send(data, to, port);
    } catch (_) {}
  }

  void _read(RawDatagramSocket s, RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    for (var d = s.receive(); d != null; d = s.receive()) {
      try {
        final h = PacketHeader.decode(d.data);
        matterLog?.call('recv ${d.data.length} bytes from ${d.address.address}:${d.port} session ${h.sessionId}');
        if (h.isGroup) continue;
        if (h.sessionId == 0) {
          final dest = h.destNodeId;
          if (dest != null) _unsecured[dest]?._deliver(h, d);
        } else {
          _secure[h.sessionId]?._deliver(h, d);
        }
      } catch (_) {
        // Garbage or a message we cannot read: drop it.
      }
    }
  }

  void close() {
    if (_closed) return;
    for (final s in [..._secure.values, ..._unsecured.values]) {
      s.close();
    }
    _closed = true;
    _v4?.close();
    _v6?.close();
  }
}

/// A conversation with one device at one address: unsecured (before PASE or
/// CASE) or secure. Owns the exchanges running over it.
abstract class Session {
  Session(this.transport, this.address, this.port, this.peerParams);

  final MatterTransport transport;
  InternetAddress address;
  int port;
  MrpParams peerParams;

  int _counter = randomIn(1, 1 << 28);
  final _received = CounterWindow();
  DateTime _lastHeard = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closed = false;
  int _nextExchange = randomIn(0, 0xffff);
  final _exchanges = <int, Exchange>{};
  final _onClose = <void Function()>[];

  /// Called for exchanges the device starts. By default only CloseSession is handled.
  void Function(Exchange exchange, MatterMessage message)? onUnsolicited;

  bool get isClosed => _closed;

  /// Our session id (0 while unsecured).
  int get localId;

  /// When the device last sent something on this session.
  DateTime get lastHeard => _lastHeard;

  void addCloseListener(void Function() f) => _onClose.add(f);

  /// The message counter and the full datagram for [payload] (protocol header plus application data).
  (int, Uint8List) _seal(Uint8List payload);

  /// The decrypted payload of a datagram, or null if it is not for us or fails its check.
  Uint8List? _open(PacketHeader header, Uint8List datagram);

  int _nextCounter() => _counter = (_counter + 1) & 0xffffffff;

  bool get _peerActive => DateTime.now().difference(_lastHeard).inMilliseconds < peerParams.activeThresholdMs;

  /// Base retransmission interval for the next message.
  int get _retransmitBaseMs => _peerActive ? peerParams.activeMs : peerParams.idleMs;

  /// How long to wait for an answer: our retransmissions, the device's
  /// processing and its own retransmissions of the answer.
  Duration get responseTimeout {
    int worst(int baseMs) {
      var total = 0.0;
      for (var n = 0; n < Exchange.maxTransmissions; n++) {
        total += baseMs * 1.1 * pow(1.6, max(0, n - 1)) * 1.25;
      }
      return total.round();
    }

    final ms = worst(_retransmitBaseMs) + worst(localMrp.activeMs) + 5000;
    return Duration(milliseconds: max(ms, 10000));
  }

  /// Starts a new exchange in which this app speaks first.
  Exchange exchange(int protocolId) {
    if (_closed) throw SessionClosedException();
    int id;
    do {
      id = _nextExchange;
      _nextExchange = (_nextExchange + 1) & 0xffff;
    } while (_exchanges.containsKey(id | 0x10000));
    final x = Exchange._(this, id, protocolId, isInitiator: true);
    _exchanges[x._key] = x;
    return x;
  }

  void _send(List<int> datagram) => transport._send(address, port, datagram);

  void _deliver(PacketHeader h, Datagram d) {
    if (_closed) return;
    final plain = _open(h, d.data);
    if (plain == null) return;
    final PayloadHeader ph;
    final Uint8List body;
    try {
      (ph, body) = PayloadHeader.decode(plain);
    } catch (_) {
      return;
    }
    _lastHeard = DateTime.now();
    // An authenticated message proves where the device is now (it may have a new address).
    if (this is SecureSession && (d.address.address != address.address || d.port != port)) {
      address = d.address;
      port = d.port;
    }
    final fresh = _received.accept(h.counter);
    var x = _exchanges[ph.initiator ? ph.exchangeId : ph.exchangeId | 0x10000];
    if (ph.ackCounter != null) x?._acked(ph.ackCounter!);
    if (!fresh) {
      // A retransmission: our ack got lost. Acknowledge again and drop it.
      if (ph.reliable) _standaloneAck(ph, h.counter);
      return;
    }
    if (ph.protocolId == Protocols.secureChannel && ph.opcode == SecureOp.standaloneAck) return;
    final msg = MatterMessage(h, ph, body);
    matterLog?.call('  protocol ${ph.protocolId} opcode 0x${ph.opcode.toRadixString(16)} exchange ${ph.exchangeId}'
        '${ph.initiator ? ' from peer' : ''}${ph.ackCounter != null ? ' ack ${ph.ackCounter}' : ''}');
    if (x == null) {
      if (!ph.initiator) {
        // A late answer in an exchange that is already over.
        if (ph.reliable) _standaloneAck(ph, h.counter);
        return;
      }
      x = Exchange._(this, ph.exchangeId, ph.protocolId, isInitiator: false);
      _exchanges[x._key] = x;
      x._received(msg);
      (onUnsolicited ?? _defaultUnsolicited)(x, msg);
      return;
    }
    x._received(msg);
  }

  void _defaultUnsolicited(Exchange x, MatterMessage m) {
    final closing = m.isStatusReport && _isCloseSession(m.statusReport);
    x.close();
    if (closing) close();
  }

  static bool _isCloseSession(StatusReport r) =>
      r.protocolId == Protocols.secureChannel && r.protocolCode == SecureChannelCode.closeSession;

  void _standaloneAck(PayloadHeader of, int counter) {
    final ph = PayloadHeader(
      exchangeId: of.exchangeId,
      protocolId: Protocols.secureChannel,
      opcode: SecureOp.standaloneAck,
      initiator: !of.initiator,
      ackCounter: counter,
    );
    _send(_seal(ph.encode(const [])).$2);
  }

  /// Ends the session. A secure session also tells the device, so it can free its slot.
  void close({bool notifyPeer = false}) {
    if (_closed) return;
    if (notifyPeer && this is SecureSession) {
      try {
        final x = exchange(Protocols.secureChannel);
        x.send(SecureOp.statusReport,
            StatusReport(0, Protocols.secureChannel, SecureChannelCode.closeSession).encode(),
            reliable: false);
      } catch (_) {}
    }
    _closed = true;
    for (final x in List.of(_exchanges.values)) {
      x._fail(SessionClosedException());
    }
    _exchanges.clear();
    transport._remove(this);
    for (final f in _onClose) {
      try {
        f();
      } catch (_) {}
    }
  }
}

/// Before PASE or CASE: plain messages tagged with a random temporary node id.
class UnsecuredSession extends Session {
  UnsecuredSession._(super.transport, super.address, super.port, super.peerParams)
      : ephemeralNodeId = randomOperationalNodeId();

  final int ephemeralNodeId;

  @override
  int get localId => 0;

  @override
  (int, Uint8List) _seal(Uint8List payload) {
    final counter = _nextCounter();
    final h = PacketHeader(sessionId: 0, counter: counter, sourceNodeId: ephemeralNodeId).encode();
    return (counter, concatBytes([h, payload]));
  }

  @override
  Uint8List? _open(PacketHeader header, Uint8List datagram) {
    if (header.destNodeId != ephemeralNodeId) return null;
    return Uint8List.sublistView(datagram, header.length);
  }
}

/// An encrypted session from PASE or CASE. This app always starts sessions,
/// so it encrypts with the initiator-to-responder key.
class SecureSession extends Session {
  SecureSession._(
    super.transport,
    super.address,
    super.port,
    super.peerParams, {
    required this.localId,
    required this.peerId,
    required this.encryptKey,
    required this.decryptKey,
    required this.attestationChallenge,
    required this.localNodeId,
    required this.peerNodeId,
  });

  /// Derives the keys from a PASE or CASE secret: I2R, R2I and the attestation
  /// challenge (Core spec 4.13.2.6), and starts listening on [localId].
  factory SecureSession.derive(
    Session over, {
    required int localId,
    required int peerId,
    required List<int> secret,
    required List<int> salt,
    MrpParams? peerParams,
    int localNodeId = 0,
    int peerNodeId = 0,
  }) {
    final keys = hkdf(secret, salt, 'SessionKeys'.codeUnits, 48);
    final s = SecureSession._(
      over.transport,
      over.address,
      over.port,
      peerParams ?? over.peerParams,
      localId: localId,
      peerId: peerId,
      encryptKey: keys.sublist(0, 16),
      decryptKey: keys.sublist(16, 32),
      attestationChallenge: keys.sublist(32, 48),
      localNodeId: localNodeId,
      peerNodeId: peerNodeId,
    );
    s._lastHeard = over._lastHeard;
    over.transport._add(s);
    return s;
  }

  @override
  final int localId;
  final int peerId;
  final Uint8List encryptKey;
  final Uint8List decryptKey;
  final Uint8List attestationChallenge;

  /// Node ids for the nonces; both 0 for PASE.
  final int localNodeId;
  final int peerNodeId;

  bool get isPase => peerNodeId == 0;

  static Uint8List _nonce(int securityFlags, int counter, int nodeId) {
    final n = Uint8List(13);
    n[0] = securityFlags;
    for (var i = 0; i < 4; i++) {
      n[1 + i] = (counter >> (8 * i)) & 0xff;
    }
    n.setRange(5, 13, le64(nodeId));
    return n;
  }

  @override
  (int, Uint8List) _seal(Uint8List payload) {
    final counter = _nextCounter();
    final h = PacketHeader(sessionId: peerId, counter: counter).encode();
    final sealed = aesCcmEncrypt(encryptKey, _nonce(0, counter, localNodeId), payload, h);
    return (counter, concatBytes([h, sealed]));
  }

  @override
  Uint8List? _open(PacketHeader header, Uint8List datagram) {
    try {
      final aad = Uint8List.sublistView(datagram, 0, header.length);
      final body = Uint8List.sublistView(datagram, header.length);
      return aesCcmDecrypt(decryptKey, _nonce(header.securityFlags, header.counter, peerNodeId), body, aad);
    } on CryptoException {
      return null;
    }
  }
}

/// One request/response conversation with reliable delivery (MRP).
class Exchange {
  Exchange._(this.session, this.id, this.protocolId, {required this.isInitiator});

  final Session session;
  final int id;
  final int protocolId;
  final bool isInitiator;

  final _inbox = Queue<MatterMessage>();
  Completer<MatterMessage>? _waiter;
  Object? _error;
  bool _closed = false;

  // The one reliable message still waiting for its acknowledgement.
  int? _unackedCounter;
  Uint8List? _unackedDatagram;
  int _transmissions = 0;
  Timer? _retransmitTimer;

  // A device message we still have to acknowledge.
  int? _pendingAck;
  Timer? _ackTimer;

  static const maxTransmissions = 5;
  static const ackDelay = Duration(milliseconds: 150);
  static final _jitter = Random();

  int get _key => isInitiator ? id | 0x10000 : id;

  bool get isClosed => _closed;

  /// Sends a message. Reliable messages are repeated until the device confirms them.
  void send(int opcode, List<int> payload, {int? protocol, bool reliable = true}) {
    if (_closed) throw MatterException('Exchange closed.');
    if (session.isClosed) throw SessionClosedException();
    if (_unackedDatagram != null) throw MatterException('The device has not confirmed the last message yet.');
    final ack = _pendingAck;
    _pendingAck = null;
    _ackTimer?.cancel();
    final ph = PayloadHeader(
      exchangeId: id,
      protocolId: protocol ?? protocolId,
      opcode: opcode,
      initiator: isInitiator,
      reliable: reliable,
      ackCounter: ack,
    );
    final (counter, datagram) = session._seal(ph.encode(payload));
    if (reliable) {
      _unackedCounter = counter;
      _unackedDatagram = datagram;
      _transmissions = 1;
      _scheduleRetransmit();
    }
    session._send(datagram);
  }

  void _scheduleRetransmit() {
    _retransmitTimer?.cancel();
    final n = _transmissions - 1; // number of the transmission just made, from 0
    final ms = session._retransmitBaseMs * 1.1 * pow(1.6, max(0, n - 1)) * (1 + _jitter.nextDouble() * 0.25);
    _retransmitTimer = Timer(Duration(milliseconds: ms.round()), () {
      final datagram = _unackedDatagram;
      if (datagram == null) return;
      if (_transmissions >= maxTransmissions || session.isClosed) {
        _unackedDatagram = null;
        _unackedCounter = null;
        _fail(MatterTimeoutException());
        return;
      }
      _transmissions++;
      session._send(datagram);
      _scheduleRetransmit();
    });
  }

  void _acked(int counter) {
    if (counter != _unackedCounter) return;
    _retransmitTimer?.cancel();
    _unackedCounter = null;
    _unackedDatagram = null;
    if (_closed) session._exchanges.remove(_key);
  }

  void _received(MatterMessage m) {
    if (m.header.reliable) {
      if (_pendingAck != null) _flushAck();
      _pendingAck = m.packet.counter;
      _ackTimer?.cancel();
      _ackTimer = Timer(ackDelay, _flushAck);
    }
    if (_closed) return;
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete(m);
    } else {
      _inbox.add(m);
    }
  }

  void _flushAck() {
    _ackTimer?.cancel();
    final counter = _pendingAck;
    if (counter == null || session.isClosed) return;
    _pendingAck = null;
    final ph = PayloadHeader(
      exchangeId: id,
      protocolId: Protocols.secureChannel,
      opcode: SecureOp.standaloneAck,
      initiator: isInitiator,
      ackCounter: counter,
    );
    session._send(session._seal(ph.encode(const [])).$2);
  }

  /// The next message the device sends in this exchange.
  Future<MatterMessage> receive({Duration? timeout}) {
    if (_inbox.isNotEmpty) return Future.value(_inbox.removeFirst());
    if (_error != null) return Future.error(_error!);
    if (_closed) return Future.error(MatterException('Exchange closed.'));
    final c = Completer<MatterMessage>();
    _waiter = c;
    return c.future.timeout(timeout ?? session.responseTimeout, onTimeout: () {
      if (identical(_waiter, c)) _waiter = null;
      throw MatterTimeoutException();
    });
  }

  /// Sends a message and waits for the reply.
  Future<MatterMessage> request(int opcode, List<int> payload, {Duration? timeout}) {
    send(opcode, payload);
    return receive(timeout: timeout);
  }

  void _fail(Object error) {
    _error ??= error;
    _ackTimer?.cancel();
    _retransmitTimer?.cancel();
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.completeError(error);
    _closed = true;
    session._exchanges.remove(_key);
  }

  /// Ends the exchange, acknowledging anything still owed. A last reliable
  /// message keeps being repeated in the background until it is confirmed.
  void close() {
    if (_closed) return;
    _flushAck();
    _closed = true;
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.completeError(MatterException('Exchange closed.'));
    if (_unackedDatagram == null) {
      _retransmitTimer?.cancel();
      session._exchanges.remove(_key);
    }
  }
}
