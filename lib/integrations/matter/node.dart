import 'clusters.dart';
import 'crypto.dart';

// What the app knows about a device on its fabric.

/// What is saved about a device on our fabric to reach it again.
class MatterNode {
  MatterNode({
    required this.nodeId,
    this.address,
    this.port = 5540,
    this.vendorId,
    this.productId,
    this.label = '',
    List<MatterEndpoint>? endpoints,
  }) : endpoints = endpoints ?? [];

  final int nodeId;

  /// Last known IP address (a string so it can be saved), and UDP port.
  String? address;
  int port;
  int? vendorId;
  int? productId;
  String label;

  /// What each endpoint is, as last read from the device.
  List<MatterEndpoint> endpoints;

  Map<String, dynamic> toJson() => {
        'id': hex64(nodeId),
        if (address != null) 'address': address,
        'port': port,
        if (vendorId != null) 'vendor': vendorId,
        if (productId != null) 'product': productId,
        'label': label,
        if (endpoints.isNotEmpty) 'endpoints': [for (final e in endpoints) e.toJson()],
      };

  factory MatterNode.fromJson(Map<String, dynamic> j) => MatterNode(
        nodeId: parseHex64(j['id'] as String),
        address: j['address'] as String?,
        port: (j['port'] as num?)?.toInt() ?? 5540,
        vendorId: (j['vendor'] as num?)?.toInt(),
        productId: (j['product'] as num?)?.toInt(),
        label: j['label'] as String? ?? '',
        endpoints: [
          for (final e in (j['endpoints'] as List? ?? const []))
            MatterEndpoint.fromJson(Map<String, dynamic>.from(e as Map)),
        ],
      );

  @override
  String toString() => 'MatterNode(${hex64(nodeId)} at $address:$port, $label)';
}

/// One endpoint of a device: what it is and which clusters it serves.
class MatterEndpoint {
  MatterEndpoint(this.id);
  final int id;
  final deviceTypes = <int>[];
  final clusters = <int>[];
  final parts = <int>[];

  /// From a bridge: the name, reachability and id of the bridged device.
  String? label;
  bool? reachable;
  String? uniqueId;

  /// The colour control feature map, when the endpoint has colour control.
  int? colorFeatures;

  bool has(int cluster) => clusters.contains(cluster);

  bool isA(int deviceType) => deviceTypes.contains(deviceType);

  Map<String, dynamic> toJson() => {
        'id': id,
        'types': deviceTypes,
        'clusters': clusters,
        if (parts.isNotEmpty) 'parts': parts,
        if (label != null) 'label': label,
        if (uniqueId != null) 'uid': uniqueId,
        if (colorFeatures != null) 'color': colorFeatures,
      };

  factory MatterEndpoint.fromJson(Map<String, dynamic> j) {
    List<int> ints(Object? v) => [for (final x in (v as List? ?? const [])) (x as num).toInt()];
    return MatterEndpoint((j['id'] as num).toInt())
      ..deviceTypes.addAll(ints(j['types']))
      ..clusters.addAll(ints(j['clusters']))
      ..parts.addAll(ints(j['parts']))
      ..label = j['label'] as String?
      ..uniqueId = j['uid'] as String?
      ..colorFeatures = (j['color'] as num?)?.toInt();
  }

  @override
  String toString() =>
      'Endpoint $id ${deviceTypes.map(DeviceType.name).join('/')} clusters ${clusters.map((c) => '0x${c.toRadixString(16)}').join(',')}';
}

class NodeDescription {
  NodeDescription({
    required this.nodeId,
    this.vendorName,
    this.vendorId,
    this.productName,
    this.productId,
    this.nodeLabel,
    this.uniqueId,
    required this.endpoints,
  });

  final int nodeId;
  final String? vendorName;
  final int? vendorId;
  final String? productName;
  final int? productId;
  final String? nodeLabel;
  final String? uniqueId;
  final List<MatterEndpoint> endpoints;

  /// The best name for the device as a whole.
  String get label => nodeLabel ?? productName ?? vendorName ?? 'Matter device';

  MatterEndpoint? endpoint(int id) => endpoints.where((e) => e.id == id).firstOrNull;
}

