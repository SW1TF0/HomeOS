import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'case.dart';
import 'certs.dart';
import 'clusters.dart';
import 'crypto.dart';
import 'discovery.dart';
import 'fabric.dart';
import 'interaction.dart';
import 'node.dart';
import 'onboarding.dart';
import 'pase.dart';
import 'session.dart';
import 'tlv.dart';

/// Adding a device that is already on the home network (Core spec 5.5,
/// "on-network commissioning"): PASE with the setup code, then our root
/// certificate and a node certificate for the device, then CASE.

/// The steps reported while adding a device, in order.
class CommissioningStep {
  static const looking = 'Looking for the device';
  static const checkingCode = 'Checking the code';
  static const securing = 'Securing the connection';
  static const adding = 'Adding it to SmartHomeKJ';
  static const reading = 'Reading what it can do';
}

enum CommissioningFailure { wrongCode, notFound, tableFull, timeout, busy, notSupported, other }

/// Why adding a device failed, with a message to show as is.
class CommissioningException extends MatterException {
  CommissioningException(this.failure, super.message);

  factory CommissioningException.of(CommissioningFailure f) => CommissioningException(f, switch (f) {
        CommissioningFailure.wrongCode =>
          'The setup code is wrong, or the device\'s pairing window has closed. Check the code, put the device in pairing mode and try again.',
        CommissioningFailure.notFound =>
          'Could not find the device on your Wi-Fi. Make sure it is powered on, in pairing mode and on the same network as this phone.',
        CommissioningFailure.tableFull =>
          'This device is already connected to as many apps as it allows. Remove it from one of them and try again.',
        CommissioningFailure.timeout =>
          'The device stopped answering. Make sure it is close to your router and try again.',
        CommissioningFailure.busy => 'Another app is adding this device right now. Try again in a few minutes.',
        CommissioningFailure.notSupported => 'This device cannot be added over Wi-Fi by this app.',
        CommissioningFailure.other => 'Could not add the device.',
      });

  final CommissioningFailure failure;
}

class Commissioner {
  Commissioner(this.transport, this.fabric, {MatterDiscovery? discovery}) : discovery = discovery ?? MatterDiscovery();

  final MatterTransport transport;
  final MatterFabric fabric;
  final MatterDiscovery discovery;

  /// Adds the device with [code]. With no [address], the device is looked up
  /// with mDNS by its discriminator. On success the device has a node
  /// certificate of [fabric] (whose next node id has moved on: save it) and the
  /// returned CASE session is open.
  Future<(MatterNode, SecureSession)> commission(
    SetupCode code, {
    InternetAddress? address,
    int port = 5540,
    void Function(String step)? onProgress,
    Duration discoveryTimeout = const Duration(seconds: 8),
  }) async {
    void step(String s) => onProgress?.call(s);

    step(CommissioningStep.looking);
    var mrp = const MrpParams();
    final candidates = <(InternetAddress, int)>[];
    if (address != null) {
      candidates.add((address, port));
    } else {
      final found = await discovery.commissionable(code: code, timeout: discoveryTimeout);
      for (final d in found) {
        for (final a in d.addresses) {
          if (transport.supports(a)) candidates.add((a, d.port));
        }
      }
      if (candidates.isEmpty) throw CommissioningException.of(CommissioningFailure.notFound);
      mrp = found.first.mrp;
    }

    step(CommissioningStep.checkingCode);
    SecureSession? pase;
    InternetAddress? paseAddress;
    var pasePort = port;
    Object? lastError;
    for (final (a, p) in candidates) {
      try {
        pase = await establishPase(transport, a, p, code.passcode, params: mrp);
        paseAddress = a;
        pasePort = p;
        break;
      } on WrongCodeException {
        throw CommissioningException.of(CommissioningFailure.wrongCode);
      } on MatterTimeoutException catch (e) {
        lastError = e;
      }
    }
    if (pase == null || paseAddress == null) {
      if (lastError is MatterTimeoutException) {
        // Nothing answered: either no device there, or its pairing window is closed.
        throw CommissioningException.of(
            address != null ? CommissioningFailure.notFound : CommissioningFailure.wrongCode);
      }
      throw CommissioningException.of(CommissioningFailure.notFound);
    }

    var failSafeArmed = false;
    SecureSession? operational;
    try {
      step(CommissioningStep.securing);
      final im = InteractionClient(pase);
      final info = await im.read(const [
        AttributePath(endpoint: 0, cluster: Cluster.generalCommissioning, attribute: GeneralCommissioning.basicCommissioningInfo),
        AttributePath(endpoint: 0, cluster: Cluster.generalCommissioning, attribute: GeneralCommissioning.locationCapability),
        AttributePath(endpoint: 0, cluster: Cluster.basicInformation, attribute: BasicInfoAttr.vendorId),
        AttributePath(endpoint: 0, cluster: Cluster.basicInformation, attribute: BasicInfoAttr.productId),
        AttributePath(endpoint: 0, cluster: Cluster.basicInformation, attribute: BasicInfoAttr.location),
        AttributePath(endpoint: 0, cluster: Cluster.operationalCredentials, attribute: OperationalCredentials.supportedFabrics),
        AttributePath(endpoint: 0, cluster: Cluster.operationalCredentials, attribute: OperationalCredentials.commissionedFabrics),
      ], fabricFiltered: false);
      final supported = info.get(0, Cluster.operationalCredentials, OperationalCredentials.supportedFabrics);
      final commissioned = info.get(0, Cluster.operationalCredentials, OperationalCredentials.commissionedFabrics);
      if (supported is int && commissioned is int && commissioned >= supported) {
        throw CommissioningException.of(CommissioningFailure.tableFull);
      }
      final basic = info.get(0, Cluster.generalCommissioning, GeneralCommissioning.basicCommissioningInfo);
      final expiry = basic is TlvStruct ? basic.integer(0) ?? 60 : 60;

      // Open the fail-safe: if anything below fails, the device undoes it all.
      final armed = await im.invoke(0, Cluster.generalCommissioning, GeneralCommissioning.armFailSafe, fields: (w) {
        w.uint(0, max(expiry, 120));
        w.uint(1, 1);
      });
      _checkCommissioningError(armed, 'ArmFailSafe');
      failSafeArmed = true;

      final capability = info.get(0, Cluster.generalCommissioning, GeneralCommissioning.locationCapability);
      final country = info.get(0, Cluster.basicInformation, BasicInfoAttr.location);
      final regulatory = await im.invoke(0, Cluster.generalCommissioning, GeneralCommissioning.setRegulatoryConfig,
          fields: (w) {
        w.uint(0, capability == 1 ? 1 : 0); // indoor, unless the device can only be outdoors
        w.string(1, country is String && RegExp(r'^[A-Z]{2}$').hasMatch(country) ? country : 'XX');
        w.uint(2, 2);
      });
      _checkCommissioningError(regulatory, 'SetRegulatoryConfig');

      // Device attestation (checking the device's DAC chain and the
      // certification declaration against the CSA's ledger) is skipped: like a
      // test commissioner, the app trusts the device the user has in hand and
      // the setup code they typed. The attestation signature in the CSR
      // response is therefore not checked either.
      final nonce = randomBytes(32);
      final csr = await im.invoke(0, Cluster.operationalCredentials, OperationalCredentials.csrRequest,
          fields: (w) => w.bytes(0, nonce));
      final elements = csr?.fields.bytes(0);
      if (elements == null) throw MatterException('The device did not send its certificate request.');
      final nocsr = decodeTlv(elements);
      if (nocsr is! TlvStruct || !bytesEqual(nocsr.bytes(2) ?? const [], nonce) || nocsr.bytes(1) == null) {
        throw MatterException('The device sent a damaged certificate request.');
      }
      final Uint8List devicePublicKey;
      try {
        devicePublicKey = publicKeyFromCsr(nocsr.bytes(1)!);
      } on CertificateException {
        throw MatterException('The device sent a damaged certificate request.');
      }

      await im.invoke(0, Cluster.operationalCredentials, OperationalCredentials.addTrustedRootCertificate,
          fields: (w) => w.bytes(0, fabric.rootCert.encode()));

      final nodeId = fabric.allocateNodeId();
      final noc = fabric.issueNoc(devicePublicKey, nodeId);
      final added = await im.invoke(0, Cluster.operationalCredentials, OperationalCredentials.addNoc, fields: (w) {
        w.bytes(0, noc.encode());
        w.bytes(2, fabric.ipkEpochKey);
        w.uint(3, fabric.controllerNodeId); // CASE admin subject: this app gets Administer rights
        w.uint(4, fabric.vendorId);
      });
      _checkNocResponse(added);

      step(CommissioningStep.adding);
      // The device now advertises itself on our fabric; find it (its address
      // can differ from the pairing one), falling back to the same address.
      final targets = <(InternetAddress, int)>[];
      MdnsService? found;
      try {
        found = await discovery.resolveOperational(fabric.instanceName(nodeId), timeout: const Duration(seconds: 4));
      } catch (_) {
        // mDNS is not available here: use the pairing address.
      }
      if (found != null) {
        for (final a in found.sortedAddresses) {
          if (transport.supports(a)) targets.add((a, found.port ?? pasePort));
        }
      }
      if (!targets.any((t) => t.$1 == paseAddress && t.$2 == pasePort)) targets.add((paseAddress, pasePort));
      Object? caseError;
      for (final (a, p) in targets) {
        try {
          operational = await establishCase(transport, fabric, nodeId, a, p, params: pase.peerParams);
          break;
        } on MatterException catch (e) {
          caseError = e;
        }
      }
      if (operational == null) {
        if (caseError is MatterTimeoutException) throw CommissioningException.of(CommissioningFailure.timeout);
        throw caseError ?? MatterException('Could not connect to the device.');
      }

      final op = InteractionClient(operational);
      final complete = await op.invoke(0, Cluster.generalCommissioning, GeneralCommissioning.commissioningComplete);
      _checkCommissioningError(complete, 'CommissioningComplete');
      failSafeArmed = false;

      // A name for our fabric in the device's list of apps. Another app may
      // already use the same label; that is harmless.
      try {
        await op.invoke(0, Cluster.operationalCredentials, OperationalCredentials.updateFabricLabel,
            fields: (w) => w.string(0, fabric.label));
      } on MatterException {
        // ignore
      }

      final node = MatterNode(
        nodeId: nodeId,
        address: operational.address.address,
        port: operational.port,
        vendorId: info.get(0, Cluster.basicInformation, BasicInfoAttr.vendorId) as int?,
        productId: info.get(0, Cluster.basicInformation, BasicInfoAttr.productId) as int?,
      );
      return (node, operational);
    } on CommissioningException {
      await _abort(pase, failSafeArmed, operational);
      rethrow;
    } on MatterTimeoutException {
      await _abort(pase, failSafeArmed, operational);
      throw CommissioningException.of(CommissioningFailure.timeout);
    } catch (e) {
      await _abort(pase, failSafeArmed, operational);
      rethrow;
    } finally {
      // The pairing session is not needed any more (the device ends it too).
      pase.close(notifyPeer: true);
    }
  }

  Future<void> _abort(SecureSession pase, bool failSafeArmed, SecureSession? operational) async {
    operational?.close(notifyPeer: true);
    if (!failSafeArmed || pase.isClosed) return;
    try {
      // Expire the fail-safe now so the device drops what was added and can be retried.
      await InteractionClient(pase).invoke(0, Cluster.generalCommissioning, GeneralCommissioning.armFailSafe,
          fields: (w) {
        w.uint(0, 0);
        w.uint(1, 0);
      }, timeout: const Duration(seconds: 5));
    } catch (_) {}
  }

  static void _checkCommissioningError(CommandResponse r, String what) {
    final code = r?.fields.integer(0) ?? 0;
    switch (code) {
      case 0:
        return;
      case 4:
        throw CommissioningException.of(CommissioningFailure.busy);
      case 3:
        throw MatterException('The device left setup mode too early ($what). Try again.');
      default:
        throw MatterException('The device refused the setup ($what, error $code${_debug(r)}).');
    }
  }

  static void _checkNocResponse(CommandResponse r) {
    final code = r?.fields.integer(0) ?? 0;
    switch (code) {
      case 0:
        return;
      case 5:
        throw CommissioningException.of(CommissioningFailure.tableFull);
      case 9:
        throw MatterException('The device is already part of SmartHomeKJ.');
      default:
        const names = {
          1: 'invalid public key',
          2: 'invalid node id',
          3: 'invalid certificate',
          4: 'missing certificate request',
          6: 'invalid admin',
          10: 'label conflict',
          11: 'invalid fabric',
        };
        throw MatterException('The device refused its certificate (${names[code] ?? 'error $code'}${_debug(r)}).');
    }
  }

  static String _debug(CommandResponse r) {
    final f = r?.fields;
    final t = [f?[1], f?[2]].whereType<String>().firstOrNull;
    return t == null || t.isEmpty ? '' : ': $t';
  }
}
