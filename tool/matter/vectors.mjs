// Prints, as JSON, the cross-check vectors that test/matter_crypto_test.dart
// and test/matter_codec_test.dart have built in, made with Node's crypto and
// matter.js. Run it from the directory where matter.js is installed (bare
// imports resolve from the current directory); matter.js logs a line first:
//
//   cd tool/matter && npm install && node --input-type=module < vectors.mjs
import crypto from "node:crypto";
import { Bytes, Spake2p, StandardCrypto } from "@matter/main";
import { Certificate, CertificateAuthority, Noc, Rcac } from "@matter/main/protocol";
import { ManualPairingCodeCodec, QrPairingCodeCodec } from "@matter/main/types";

const hex = (b) => Buffer.from(b).toString("hex");
const fromHex = (h) => Buffer.from(h, "hex");
const out = {};

// AES-128-CCM with a 16-byte tag, as Matter uses it.
out.ccm = [];
for (const [key, nonce, pt, aad] of [
  ["000102030405060708090a0b0c0d0e0f", "101112131415161718191a1b1c", "", ""],
  ["5eded244e2a6ad4ad3d1f6b49f28fa0a", "00010203040506070809101112", "48656c6c6f204d6174746572", "0011223344"],
  [
    "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf",
    "4e434153455f5369676d61324e",
    "1530014c0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f3031323334353637",
    "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d",
  ],
]) {
  const c = crypto.createCipheriv("aes-128-ccm", fromHex(key), fromHex(nonce), { authTagLength: 16 });
  if (aad) c.setAAD(fromHex(aad), { plaintextLength: pt.length / 2 });
  const ct = Buffer.concat([c.update(fromHex(pt)), c.final(), c.getAuthTag()]);
  out.ccm.push({ key, nonce, pt, aad, ct: hex(ct) });
}

// HKDF-SHA256 and PBKDF2-HMAC-SHA256.
out.hkdf = [
  ["0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b", "", "SessionKeys", 48],
  ["000102030405060708090a0b0c0d0e0f", "a0a1a2a3a4a5a6a7", "CompressedFabric", 8],
  ["deadbeef", "0102", "Sigma2", 16],
].map(([ikm, salt, info, len]) => ({
  ikm, salt, info, len,
  okm: hex(crypto.hkdfSync("sha256", fromHex(ikm), fromHex(salt), Buffer.from(info), len)),
}));
out.pbkdf2 = [
  ["15cd0c00", "5350414b453250204b65792053616c74", 1000, 80],
  ["15cd0c00", "0102030405060708090a0b0c0d0e0f10", 2000, 80],
].map(([pw, salt, iterations, len]) => ({
  pw, salt, iterations, len,
  dk: hex(crypto.pbkdf2Sync(fromHex(pw), fromHex(salt), iterations, len, "sha256")),
}));

// SPAKE2+ between matter.js prover and verifier with fixed scalars.
const sc = new StandardCrypto();
const salt = Bytes.fromHex("5350414b453250204b65792053616c74");
const { w0, w1 } = await Spake2p.computeW0W1(sc, { iterations: 1000, salt }, 20202021);
const { L } = await Spake2p.computeW0L(sc, { iterations: 1000, salt }, 20202021);
const context = await sc.computeHash(Bytes.fromString("SPAKE2+ test context"));
const x = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdefn;
const y = 0x0fedcba0987654321fedcba0987654321fedcba0987654321fedcba098765432n;
const prover = new Spake2p(sc, context, x, w0);
const verifier = new Spake2p(sc, context, y, w0);
const X = prover.computeX();
const Y = verifier.computeY();
const p = await prover.computeSecretAndVerifiersFromY(w1, X, Y);
const v = await verifier.computeSecretAndVerifiersFromX(L, X, Y);
out.spake = {
  passcode: 20202021, salt: hex(salt), iterations: 1000, context: hex(context),
  x: x.toString(16), y: y.toString(16),
  w0: w0.toString(16).padStart(64, "0"), w1: w1.toString(16).padStart(64, "0"),
  X: hex(X), Y: hex(Y), Ke: hex(p.Ke), cA: hex(p.hAY), cB: hex(p.hBX), verifierKe: hex(v.Ke),
};

// A root and a node certificate made and signed by matter.js.
const ca = await CertificateAuthority.create(sc);
const key = await sc.createKeyPair();
const noc = await ca.generateNoc(key.publicKey, 0x1122334455667788n, 0x0000000000000042n);
out.certs = {
  rcac: hex(ca.rootCert),
  rcacTbs: hex(Rcac.fromTlv(ca.rootCert).asUnsignedDer()),
  rcacDer: hex(Rcac.fromTlv(ca.rootCert).asSignedDer()),
  noc: hex(noc),
  nocTbs: hex(Noc.fromTlv(noc).asUnsignedDer()),
  nocPublicKey: hex(key.publicKey),
};

// A certificate signing request made by matter.js, and the key it is for.
const csrKey = await sc.createKeyPair();
out.csr = {
  csr: hex(await Certificate.createCertificateSigningRequest(sc, csrKey)),
  publicKey: hex(csrKey.publicKey),
};

// The Core specification's test vectors for the compressed fabric id, the
// operational IPK and the CASE destination id, recomputed with Node's crypto
// (matchesSpec says whether they agree with the values printed in the spec).
{
  const rootPub = fromHex(
    "044a9f42b1ca4840d37292bbc7f6a7e11e22200c976fc900dbc98a7a383a641cb8254a2e56d4e295a847943b4e3897c4a773e930277b4d9fbede8a052686bfacfa",
  );
  const fabricId = 0x2906c908d115d362n;
  const nodeId = 0xcd5544aa7b13ef14n;
  const be = (v) => { const b = Buffer.alloc(8); b.writeBigUInt64BE(v); return b; };
  const le = (v) => { const b = Buffer.alloc(8); b.writeBigUInt64LE(v); return b; };
  const cfid = Buffer.from(crypto.hkdfSync("sha256", rootPub.subarray(1), be(fabricId), Buffer.from("CompressedFabric"), 8));
  const epochKey = fromHex("4a71cdd7b2a3ca9024f96f3c96a19dee");
  const ipk = Buffer.from(crypto.hkdfSync("sha256", epochKey, cfid, Buffer.from("GroupKey v1.0"), 16));
  const random = fromHex("7e171231568dfa17206b3accf8faec2f4d21b580113196f47c7c4deb810a73dc");
  const dest = crypto.createHmac("sha256", ipk).update(Buffer.concat([random, rootPub, le(fabricId), le(nodeId)])).digest();
  out.fabric = {
    rootPublicKey: hex(rootPub), fabricId: fabricId.toString(16), nodeId: nodeId.toString(16),
    compressedFabricId: hex(cfid), epochKey: hex(epochKey), ipk: hex(ipk), random: hex(random), destinationId: hex(dest),
    matchesSpec: hex(cfid) === "87e1b004e235a130" && hex(ipk) === "9bc61cd9c62a2df6d64dfcaa9dc472d4" &&
      hex(dest) === "dc35dd5fc9134cc5544538c9c3fc4297c1ec3370c839136a80e10796451d4c53",
  };
}

// Setup codes made by matter.js.
out.codes = [
  { passcode: 20202021, discriminator: 3840, vendorId: 0xfff1, productId: 0x8000, flowType: 0, discoveryCapabilities: 4 },
  { passcode: 12345679, discriminator: 0x123, vendorId: 0x1234, productId: 0x5678, flowType: 0, discoveryCapabilities: 2 },
  { passcode: 99999998, discriminator: 0xfff, vendorId: 0xfff2, productId: 1, flowType: 2, discoveryCapabilities: 6 },
  { passcode: 1, discriminator: 0, vendorId: 0, productId: 0, flowType: 0, discoveryCapabilities: 0 },
].map((c) => ({
  ...c,
  qr: QrPairingCodeCodec.encode([{ version: 0, ...c }]),
  manual: ManualPairingCodeCodec.encode({ passcode: c.passcode, discriminator: c.discriminator }),
  manualLong: ManualPairingCodeCodec.encode({
    passcode: c.passcode, discriminator: c.discriminator, vendorId: c.vendorId, productId: c.productId, flowType: 2,
  }),
}));

process.stdout.write(JSON.stringify(out, null, 1) + "\n");
