import base64

from steam_mafile.crypto import (
    generate_device_id, generate_guard_code, rsa_encrypt_password,
)


def test_guard_code_regression_vectors():
    # Значения зафиксированы и сверены с независимой реализацией алгоритма.
    zero = base64.b64encode(b"\x00" * 20).decode()
    seq = base64.b64encode(bytes(range(20))).decode()
    assert generate_guard_code(zero, 0) == "RYH4D"
    assert generate_guard_code(zero, 1_000_000) == "N26TY"
    assert generate_guard_code(seq, 1_600_000_000) == "2GJY4"


def test_guard_code_is_five_chars_from_alphabet():
    secret = base64.b64encode(b"\x11" * 20).decode()
    code = generate_guard_code(secret, 1234567890)
    assert len(code) == 5
    assert all(c in "23456789BCDFGHJKMNPQRTVWXY" for c in code)


def test_guard_code_stable_within_30s_window():
    secret = base64.b64encode(b"\x22" * 20).decode()
    assert generate_guard_code(secret, 300) == generate_guard_code(secret, 329)
    assert generate_guard_code(secret, 300) != generate_guard_code(secret, 330)


def test_device_id_format():
    did = generate_device_id()
    assert did.startswith("android:")
    assert len(did) > len("android:")
    assert generate_device_id() != generate_device_id()


def _egcd(a, b):
    if b == 0:
        return a, 1, 0
    g, x, y = _egcd(b, a % b)
    return g, y, x - (a // b) * y


def _modinv(a, m):
    return _egcd(a, m)[1] % m


# Настоящие 256-битные простые числа -> 511-битный модуль (>= 63 байта),
# достаточно для проверки PKCS#1 v1.5 паддинга без обращения к сети.
_P = 0xa970654f01a27ae2e8ba456afd3cc7afb61ce648f6b5579986340356d3285e85
_Q = 0x9b79e8092b3e2660b79b687b9f24227b528f1e38d8d1e33220d09330d9781203


def test_rsa_encrypt_roundtrip():
    n = _P * _Q
    phi = (_P - 1) * (_Q - 1)
    e = 65537
    d = _modinv(e, phi)
    mod_hex = format(n, "x")
    exp_hex = format(e, "x")

    password = "MyS3cretPass!é"
    b64 = rsa_encrypt_password(password, mod_hex, exp_hex)
    cipher = int.from_bytes(base64.b64decode(b64), "big")
    plain = pow(cipher, d, n)

    k = (n.bit_length() + 7) // 8
    block = plain.to_bytes(k, "big")
    assert block[0:2] == b"\x00\x02"          # маркер PKCS#1 type 2
    sep = block.index(b"\x00", 2)
    assert sep >= 2 + 8                        # минимум 8 байт паддинга
    assert block[sep + 1:].decode("utf-8") == password
