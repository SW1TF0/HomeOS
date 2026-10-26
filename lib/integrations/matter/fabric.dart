import 'dart:convert';
import 'dart:typed_data';

import 'certs.dart';
import 'crypto.dart';
import 'session.dart';

/// The app's own Matter fabric: a private certificate authority whose root
/// every added device trusts, and the app's identity on it (Core spec 2.5, 6.4).
///
/// Everything here is saved with [toJson] and must be kept: without the root
/// key the app can no longer talk to the devices it added.
class MatterFabric {
  MatterFabric({
    required this.rootKey,
    required this.rootCert,
    required this.fabricId,
    required this.controllerNodeId,
    required this.controllerKey,
    required this.controllerNoc,
    required this.ipkEpochKey,
    required this.nextNodeId,
    this.vendorId = 0xFFF1,
    this.label = 'SmartHomeKJ',
  });

  /// A new fabric with fresh keys.
  factory MatterFabric.create({String label = 'SmartHomeKJ', int vendorId = 0xFFF1}) {
    final rootKey = EcKeyPair.generate();
    final root = issueRootCertificate(rootKey, rcacId: randomOperationalNodeId());
    final fabricId = randomOperationalNodeId();
    final nodeId = randomOperationalNodeId();
    final key = EcKeyPair.generate();
    return MatterFabric(
      rootKey: rootKey,
      rootCert: root,
      fabricId: fabricId,
      controllerNodeId: nodeId,
      controllerKey: key,
      controllerNoc: issueNodeCertificate(
          rootKey: rootKey, root: root, publicKey: key.publicKey, nodeId: nodeId, fabricId: fabricId),
      ipkEpochKey: randomBytes(16),
      nextNodeId: 1 + randomIn(0, 0xffff),
      vendorId: vendorId,
      label: label,
    );
  }

  final EcKeyPair rootKey;
  final MatterCertificate rootCert;
  final int fabricId;
  final int controllerNodeId;
  final EcKeyPair controllerKey;
  final MatterCertificate controllerNoc;

  /// The identity protection key's epoch key, given to every device in AddNOC.
  final Uint8List ipkEpochKey;

  /// The node id the next added device gets.
  int nextNodeId;
  final int vendorId;
  final String label;

  Uint8List get rootPublicKey => rootCert.publicKey;

  /// The 64-bit id devices advertise this fabric under (Core spec 4.3.2.2).
  late final int compressedFabricId = beToInt(
      hkdf(rootPublicKey.sublist(1), be64(fabricId), utf8.encode('CompressedFabric'), 8));

  /// The operational identity protection key (Core spec 4.17.2).
  late final Uint8List operationalIpk =
      hkdf(ipkEpochKey, be64(compressedFabricId), utf8.encode('GroupKey v1.0'), 16);

  /// Tells a device which fabric and node a CASE request is for (Core spec 4.14.2.4.1).
  Uint8List destinationId(List<int> initiatorRandom, int nodeId) => hmacSha256(
      operationalIpk, [...initiatorRandom, ...rootPublicKey, ...le64(fabricId), ...le64(nodeId)]);

  /// The mDNS instance name of [nodeId] under `_matter._tcp`.
  String instanceName(int nodeId) => '${hex64(compressedFabricId)}-${hex64(nodeId)}';

  /// Hands out the node id for a device being added.
  int allocateNodeId() {
    var id = nextNodeId;
    if (id <= 0 || (id >>> 32) >= 0xFFFFFFF0 || id == controllerNodeId) id = 1;
    nextNodeId = id + 1;
    return id;
  }

  MatterCertificate issueNoc(List<int> publicKey, int nodeId) => issueNodeCertificate(
      rootKey: rootKey, root: rootCert, publicKey: publicKey, nodeId: nodeId, fabricId: fabricId);

  /// Checks that [noc] was issued by this fabric for [nodeId].
  bool owns(MatterCertificate noc, int nodeId) =>
      noc.fabricId == fabricId && noc.nodeId == nodeId && noc.verifySignature(rootPublicKey);

  /// Plain JSON data (strings and ints only) to save in the app's settings.
  Map<String, dynamic> toJson() => {
        'version': 1,
        'fabricId': hex64(fabricId),
        'rootKey': hexOf(rootKey.privateKey),
        'rootCert': base64.encode(rootCert.encode()),
        'nodeId': hex64(controllerNodeId),
        'key': hexOf(controllerKey.privateKey),
        'noc': base64.encode(controllerNoc.encode()),
        'ipk': hexOf(ipkEpochKey),
        'nextNodeId': hex64(nextNodeId),
        'vendorId': vendorId,
        'label': label,
      };

  factory MatterFabric.fromJson(Map<String, dynamic> j) {
    try {
      final rootKey = EcKeyPair.fromPrivate(hexBytes(j['rootKey'] as String));
      final root = MatterCertificate.decode(base64.decode(j['rootCert'] as String));
      final key = EcKeyPair.fromPrivate(hexBytes(j['key'] as String));
      final noc = MatterCertificate.decode(base64.decode(j['noc'] as String));
      if (!bytesEqual(root.publicKey, rootKey.publicKey) || !bytesEqual(noc.publicKey, key.publicKey)) {
        throw const FormatException('keys do not match the certificates');
      }
      return MatterFabric(
        rootKey: rootKey,
        rootCert: root,
        fabricId: parseHex64(j['fabricId'] as String),
        controllerNodeId: parseHex64(j['nodeId'] as String),
        controllerKey: key,
        controllerNoc: noc,
        ipkEpochKey: hexBytes(j['ipk'] as String),
        nextNodeId: parseHex64(j['nextNodeId'] as String),
        vendorId: (j['vendorId'] as num?)?.toInt() ?? 0xFFF1,
        label: j['label'] as String? ?? 'SmartHomeKJ',
      );
    } on Object catch (e) {
      if (e is MatterException) rethrow;
      throw MatterException('The saved Matter settings are damaged ($e).');
    }
  }
}
