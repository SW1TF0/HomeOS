import 'dart:async';
import 'dart:typed_data';

import 'message.dart';
import 'session.dart';
import 'tlv.dart';

/// The Interaction Model (Core spec chapter 8): reading and writing
/// attributes and invoking commands over a secure session.

/// An attribute to read. Null parts are wildcards (all endpoints, all attributes...).
class AttributePath {
  const AttributePath({this.endpoint, this.cluster, this.attribute});
  final int? endpoint;
  final int? cluster;
  final int? attribute;

  @override
  String toString() => '${endpoint ?? '*'}/${_h(cluster)}/${_h(attribute)}';
}

String _h(int? v) => v == null ? '*' : '0x${v.toRadixString(16)}';

/// One value from a read. [value] is a TLV value: int, bool, double, String,
/// Uint8List, null, a [TlvStruct] or a List.
class AttributeValue {
  AttributeValue(this.endpoint, this.cluster, this.attribute, this.value, [this.dataVersion]);
  final int endpoint;
  final int cluster;
  final int attribute;
  Object? value;
  final int? dataVersion;

  @override
  String toString() => '$endpoint/${_h(cluster)}/${_h(attribute)} = $value';
}

/// The result of a read: values and per-path errors.
class ReadResult {
  final values = <AttributeValue>[];

  /// Paths the device refused, with their status (for example unsupported attribute).
  final errors = <(AttributePath, int)>[];

  AttributeValue? find(int endpoint, int cluster, int attribute) {
    for (final v in values) {
      if (v.endpoint == endpoint && v.cluster == cluster && v.attribute == attribute) return v;
    }
    return null;
  }

  Object? get(int endpoint, int cluster, int attribute) => find(endpoint, cluster, attribute)?.value;

  Iterable<AttributeValue> where({int? endpoint, int? cluster, int? attribute}) => values.where((v) =>
      (endpoint == null || v.endpoint == endpoint) &&
      (cluster == null || v.cluster == cluster) &&
      (attribute == null || v.attribute == attribute));
}

/// A status from the Interaction Model (Core spec 8.10).
class ImStatus {
  static const success = 0x00;
  static const failure = 0x01;
  static const invalidSubscription = 0x7d;
  static const unsupportedAccess = 0x7e;
  static const unsupportedEndpoint = 0x7f;
  static const invalidAction = 0x80;
  static const unsupportedCommand = 0x81;
  static const invalidCommand = 0x85;
  static const unsupportedAttribute = 0x86;
  static const constraintError = 0x87;
  static const unsupportedWrite = 0x88;
  static const resourceExhausted = 0x89;
  static const notFound = 0x8b;
  static const unreportableAttribute = 0x8c;
  static const invalidDataType = 0x8d;
  static const unsupportedRead = 0x8f;
  static const dataVersionMismatch = 0x92;
  static const timeout = 0x94;
  static const unsupportedNode = 0x9b;
  static const busy = 0x9c;
  static const accessRestricted = 0x9d;
  static const unsupportedCluster = 0xc3;
  static const noUpstreamSubscription = 0xc5;
  static const needsTimedInteraction = 0xc6;
  static const unsupportedEvent = 0xc7;
  static const pathsExhausted = 0xc8;
  static const timedRequestMismatch = 0xc9;
  static const failsafeRequired = 0xca;
  static const invalidInState = 0xcb;
  static const noCommandResponse = 0xcc;

  static String describe(int status) => switch (status) {
        success => 'success',
        failure => 'the device reported a failure',
        unsupportedAccess => 'SmartMenuKJ is not allowed to do that on this device',
        unsupportedEndpoint => 'the device has no such part',
        invalidAction => 'the device did not accept the request',
        unsupportedCommand => 'the device does not support that command',
        invalidCommand => 'the device rejected the command',
        unsupportedAttribute => 'the device does not have that setting',
        constraintError => 'the value is out of range for this device',
        unsupportedWrite => 'that setting cannot be changed',
        resourceExhausted => 'the device is out of resources',
        notFound => 'the device could not find what was asked for',
        unreportableAttribute => 'that value cannot be read',
        invalidDataType => 'the device did not understand the value',
        unsupportedRead => 'that value cannot be read',
        dataVersionMismatch => 'the device changed in the meantime, try again',
        timeout => 'the device timed out',
        unsupportedNode => 'the device does not accept that request',
        busy => 'the device is busy, try again in a moment',
        accessRestricted => 'access to that is restricted on this device',
        unsupportedCluster => 'the device does not support that feature',
        needsTimedInteraction => 'the device needs a timed request for that',
        unsupportedEvent => 'the device does not have that event',
        pathsExhausted => 'too many things were asked at once',
        timedRequestMismatch => 'the timed request did not match',
        failsafeRequired => 'the device needs to be in setup mode for that',
        invalidInState => 'the device cannot do that right now',
        noCommandResponse => 'the device did not answer the command',
        _ => 'status 0x${status.toRadixString(16)}',
      };
}

class ImStatusException extends MatterException {
  ImStatusException(this.status, {this.clusterStatus, String? context})
      : super('${context == null ? '' : '$context: '}${ImStatus.describe(status)}'
            '${clusterStatus == null ? '' : ' (code $clusterStatus)'}.');
  final int status;
  final int? clusterStatus;
}

/// A command's response data, or null for commands that only answer with a status.
typedef CommandResponse = ({int command, TlvStruct fields})?;

/// Reads, writes and invokes over one [session].
class InteractionClient {
  InteractionClient(this.session);

  final Session session;

  /// Devices must accept at least 9 paths per read (Core spec 8.5.1).
  static const maxPathsPerRead = 9;

  /// Reads [paths], splitting them into several requests when there are many.
  Future<ReadResult> read(List<AttributePath> paths, {bool fabricFiltered = true, Duration? timeout}) async {
    final result = ReadResult();
    for (var i = 0; i < paths.length; i += maxPathsPerRead) {
      await _read(paths.sublist(i, (i + maxPathsPerRead).clamp(0, paths.length)), fabricFiltered, result, timeout);
    }
    return result;
  }

  /// Reads one attribute and returns its value; throws when the device reports an error.
  Future<Object?> readAttribute(int endpoint, int cluster, int attribute) async {
    final r = await read([AttributePath(endpoint: endpoint, cluster: cluster, attribute: attribute)]);
    final v = r.find(endpoint, cluster, attribute);
    if (v != null) return v.value;
    if (r.errors.isNotEmpty) throw ImStatusException(r.errors.first.$2);
    throw MatterException('The device did not report ${_h(cluster)}/${_h(attribute)}.');
  }

  Future<void> _read(List<AttributePath> paths, bool fabricFiltered, ReadResult result, Duration? timeout) async {
    final request = tlvStruct((w) {
      w.array(0, (w) {
        for (final p in paths) {
          w.list(null, (w) {
            if (p.endpoint != null) w.uint(2, p.endpoint!);
            if (p.cluster != null) w.uint(3, p.cluster!);
            if (p.attribute != null) w.uint(4, p.attribute!);
          });
        }
      });
      w.boolean(3, fabricFiltered);
      w.uint(0xff, imRevision);
    });
    final x = session.exchange(Protocols.interactionModel);
    try {
      var m = await x.request(ImOp.readRequest, request, timeout: timeout);
      while (true) {
        _checkStatusResponse(m, 'Reading');
        if (m.opcode != ImOp.reportData) throw MatterException('The device sent an unexpected answer.');
        final report = _struct(m.payload);
        _collect(report, result);
        final more = report.boolean(3) ?? false;
        final suppress = report.boolean(4) ?? false;
        if (more || !suppress) x.send(ImOp.statusResponse, _statusResponse(ImStatus.success));
        if (!more) break;
        m = await x.receive(timeout: timeout);
      }
    } finally {
      x.close();
    }
  }

  void _collect(TlvStruct report, ReadResult result) {
    final reports = report.array(1) ?? const [];
    for (final r in reports) {
      if (r is! TlvStruct) continue;
      final status = r.struct(0);
      if (status != null) {
        final p = status.struct(0);
        final s = status.struct(1);
        result.errors.add((
          AttributePath(endpoint: p?.integer(2), cluster: p?.integer(3), attribute: p?.integer(4)),
          s?.integer(0) ?? ImStatus.failure,
        ));
        continue;
      }
      final data = r.struct(1);
      final path = data?.struct(1);
      if (data == null || path == null) continue;
      final ep = path.integer(2), cl = path.integer(3), at = path.integer(4);
      if (ep == null || cl == null || at == null) continue;
      final value = data[2];
      if (path.has(5)) {
        // List chunking: an item appended to a list sent earlier in this read.
        final existing = result.find(ep, cl, at);
        if (existing != null && existing.value is List) {
          (existing.value as List).add(value);
          continue;
        }
        result.values.add(AttributeValue(ep, cl, at, <Object?>[value], data.integer(0)));
        continue;
      }
      final copy = value is List ? List<Object?>.of(value) : value;
      final existing = result.find(ep, cl, at);
      if (existing != null) {
        existing.value = copy;
      } else {
        result.values.add(AttributeValue(ep, cl, at, copy, data.integer(0)));
      }
    }
  }

  /// Invokes a command. [fields] writes the command's fields (context tags
  /// from 0). With [timed], a timed request opens a window of that length
  /// first, which some commands require (door locks, commissioning steps).
  Future<CommandResponse> invoke(int endpoint, int cluster, int command,
      {void Function(TlvWriter w)? fields, Duration? timed, Duration? timeout}) async {
    final x = session.exchange(Protocols.interactionModel);
    try {
      if (timed != null) await _timed(x, timed, timeout);
      final request = tlvStruct((w) {
        w.boolean(0, false);
        w.boolean(1, timed != null);
        w.array(2, (w) {
          w.struct(null, (w) {
            w.list(0, (w) {
              w.uint(0, endpoint);
              w.uint(1, cluster);
              w.uint(2, command);
            });
            w.struct(1, (w) => fields?.call(w));
          });
        });
        w.uint(0xff, imRevision);
      });
      var m = await x.request(ImOp.invokeRequest, request, timeout: timeout);
      CommandResponse response;
      while (true) {
        _checkStatusResponse(m, 'Command');
        if (m.opcode != ImOp.invokeResponse) throw MatterException('The device sent an unexpected answer.');
        final r = _struct(m.payload);
        for (final item in r.array(1) ?? const []) {
          if (item is! TlvStruct) continue;
          final data = item.struct(0);
          if (data != null) {
            final path = data.struct(0);
            response = (command: path?.integer(2) ?? -1, fields: data.struct(1) ?? TlvStruct(const []));
          }
          final status = item.struct(1)?.struct(1);
          if (status != null) {
            final code = status.integer(0) ?? ImStatus.failure;
            if (code != ImStatus.success) {
              throw ImStatusException(code, clusterStatus: status.integer(1), context: 'Command');
            }
          }
        }
        if (!(r.boolean(2) ?? false)) break;
        x.send(ImOp.statusResponse, _statusResponse(ImStatus.success));
        m = await x.receive(timeout: timeout);
      }
      return response;
    } finally {
      x.close();
    }
  }

  /// Writes one attribute. [value] writes the value with the tag it is given.
  Future<void> write(int endpoint, int cluster, int attribute, void Function(TlvWriter w, int tag) value,
      {Duration? timed, Duration? timeout}) async {
    final x = session.exchange(Protocols.interactionModel);
    try {
      if (timed != null) await _timed(x, timed, timeout);
      final request = tlvStruct((w) {
        w.boolean(0, false);
        w.boolean(1, timed != null);
        w.array(2, (w) {
          w.struct(null, (w) {
            w.list(1, (w) {
              w.uint(2, endpoint);
              w.uint(3, cluster);
              w.uint(4, attribute);
            });
            value(w, 2);
          });
        });
        w.uint(0xff, imRevision);
      });
      final m = await x.request(ImOp.writeRequest, request, timeout: timeout);
      _checkStatusResponse(m, 'Writing');
      if (m.opcode != ImOp.writeResponse) throw MatterException('The device sent an unexpected answer.');
      for (final item in _struct(m.payload).array(0) ?? const []) {
        if (item is! TlvStruct) continue;
        final status = item.struct(1);
        final code = status?.integer(0) ?? ImStatus.success;
        if (code != ImStatus.success) {
          throw ImStatusException(code, clusterStatus: status?.integer(1), context: 'Writing');
        }
      }
    } finally {
      x.close();
    }
  }

  Future<void> _timed(Exchange x, Duration window, Duration? timeout) async {
    final m = await x.request(
        ImOp.timedRequest,
        tlvStruct((w) {
          w.uint(0, window.inMilliseconds.clamp(1, 0xffff));
          w.uint(0xff, imRevision);
        }),
        timeout: timeout);
    _checkStatusResponse(m, 'Timed request');
    if (m.opcode != ImOp.statusResponse) throw MatterException('The device sent an unexpected answer.');
  }

  static Uint8List _statusResponse(int status) => tlvStruct((w) {
        w.uint(0, status);
        w.uint(0xff, imRevision);
      });

  static void _checkStatusResponse(MatterMessage m, String context) {
    if (m.protocolId != Protocols.interactionModel) {
      if (m.isStatusReport) throw MatterException('$context failed: ${m.statusReport.reason}.');
      throw MatterException('The device sent an unexpected answer.');
    }
    if (m.opcode != ImOp.statusResponse) return;
    final status = _struct(m.payload).integer(0) ?? ImStatus.failure;
    if (status != ImStatus.success) throw ImStatusException(status, context: context);
  }

  static TlvStruct _struct(Uint8List payload) {
    try {
      final v = decodeTlv(payload);
      if (v is TlvStruct) return v;
    } on TlvFormatException {
      // fall through
    } on RangeError {
      // fall through
    }
    throw MatterException('The device sent a message this app cannot read.');
  }
}
