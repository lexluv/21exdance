import base64
import hashlib
import hmac
import os
import struct
import uuid

GUARD_ALPHABET = "23456789BCDFGHJKMNPQRTVWXY"


def rsa_encrypt_password(password: str, modulus_hex: str, exponent_hex: str) -> str:
    """RSA PKCS#1 v1.5, как это делает клиент Steam. Возвращает base64."""
    n = int(modulus_hex, 16)
    e = int(exponent_hex, 16)
    k = (n.bit_length() + 7) // 8
    message = password.encode("utf-8")
    if len(message) > k - 11:
        raise ValueError("пароль слишком длинный для ключа RSA")
    padding = bytearray()
    while len(padding) < k - len(message) - 3:
        padding += bytes(b for b in os.urandom(k) if b != 0)
    block = b"\x00\x02" + bytes(padding[:k - len(message) - 3]) + b"\x00" + message
    cipher = pow(int.from_bytes(block, "big"), e, n)
    return base64.b64encode(cipher.to_bytes(k, "big")).decode("ascii")


def generate_guard_code(shared_secret: str, timestamp: int) -> str:
    """5-символьный код Steam Guard для заданного серверного времени."""
    key = base64.b64decode(shared_secret)
    digest = hmac.new(key, struct.pack(">Q", timestamp // 30), hashlib.sha1).digest()
    offset = digest[19] & 0x0F
    value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    code = ""
    for _ in range(5):
        code += GUARD_ALPHABET[value % len(GUARD_ALPHABET)]
        value //= len(GUARD_ALPHABET)
    return code


def generate_device_id() -> str:
    return "android:" + str(uuid.uuid4())
