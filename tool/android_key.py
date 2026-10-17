"""Makes the app's Android signing key from the ANDROID_SIGNING_SECRET secret.

The key and its certificate are worked out from the secret alone, the same way every time, so every build is signed
with the same key and installs over the version before, while nothing secret is stored in the repository.

    ANDROID_SIGNING_SECRET=... python3 tool/android_key.py android/app/release-key.p12

writes a PKCS#12 keystore (password and alias "smartmenukj") and prints APP_KEY_SHA256=<certificate SHA-256>.
Needs the cryptography package, 44 or newer (for deterministic ECDSA).
"""
import datetime
import hashlib
import os
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

# Order of the P-256 group.
_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
_SALT = b'SmartMenuKJ Android signing key v1'
# The keystore only lives on the build machine; the secret is what protects the key.
PASSWORD = b'smartmenukj'
# A known answer. If a library update ever changed how keys come out, no update would install over the old app any
# more, so the build stops instead.
_CHECK = ('test secret that is long enough', 'eb1057eec6df88a37df8dfe1623a4b60a75da567db4f0825030becf118f63015')


def make(secret):
    secret = secret.strip()
    if len(secret) < 16:
        raise SystemExit('ANDROID_SIGNING_SECRET must be at least 16 characters long.')
    # scrypt makes guessing the secret from the public certificate slow.
    seed = hashlib.scrypt(secret.encode(), salt=_SALT, n=2**17, r=8, p=1, maxmem=256 * 1024 * 1024, dklen=48)
    key = ec.derive_private_key(int.from_bytes(seed, 'big') % (_N - 1) + 1, ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'SmartMenuKJ'),
                      x509.NameAttribute(NameOID.ORGANIZATION_NAME, 'SmartMenuKJ')])
    # Every field is fixed and the signature is deterministic (RFC 6979), so the certificate never changes.
    cert = (x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(name)
            .public_key(key.public_key())
            .serial_number(1)
            .not_valid_before(datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc))
            .not_valid_after(datetime.datetime(2076, 1, 1, tzinfo=datetime.timezone.utc))
            .sign(key, hashes.SHA256(), ecdsa_deterministic=True))
    return key, cert


def keystore(key, cert):
    encryption = (serialization.PrivateFormat.PKCS12.encryption_builder()
                  .kdf_rounds(10000)
                  .key_cert_algorithm(pkcs12.PBES.PBESv2SHA256AndAES256CBC)
                  .hmac_hash(hashes.SHA256())
                  .build(PASSWORD))
    return pkcs12.serialize_key_and_certificates(b'smartmenukj', key, cert, None, encryption)


if __name__ == '__main__':
    if make(_CHECK[0])[1].fingerprint(hashes.SHA256()).hex() != _CHECK[1]:
        raise SystemExit('Keys come out differently than before: keep the cryptography version that made them.')
    key, cert = make(os.environ.get('ANDROID_SIGNING_SECRET', ''))
    with open(sys.argv[1], 'wb') as f:
        f.write(keystore(key, cert))
    print('APP_KEY_SHA256=' + cert.fingerprint(hashes.SHA256()).hex())
