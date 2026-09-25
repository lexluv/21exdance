import struct

from steam_mafile.protobuf import (
    Message, Writer, decode_varint, encode_varint,
)


def test_varint_roundtrip():
    for v in [0, 1, 127, 128, 300, 16384, 2**32, 2**63 - 1]:
        enc = encode_varint(v)
        dec, pos = decode_varint(enc, 0)
        assert dec == v
        assert pos == len(enc)


def test_writer_message_roundtrip():
    inner = Writer().varint(1, 5).string(2, "hi")
    data = (
        Writer()
        .string(1, "name")
        .varint(2, 300)
        .fixed64(3, 76561198000000000)
        .bytes(4, b"\x01\x02\x03")
        .bool(5, True)
        .message(6, inner)
        .build()
    )
    m = Message(data)
    assert m.get_str(1) == "name"
    assert m.get_int(2) == 300
    assert m.get_int(3) == 76561198000000000
    assert m.get_bytes(4) == b"\x01\x02\x03"
    assert m.get_int(5) == 1
    sub = m.get_messages(6)[0]
    assert sub.get_int(1) == 5
    assert sub.get_str(2) == "hi"


def test_repeated_fields():
    data = Writer().varint(1, 10).varint(1, 20).varint(1, 30).build()
    m = Message(data)
    assert m.fields[1] == [10, 20, 30]
    assert m.get_int(1) == 30  # get_* возвращает последнее


def test_defaults_for_missing_fields():
    m = Message(b"")
    assert m.get_int(1) == 0
    assert m.get_str(2) == ""
    assert m.get_bytes(3) == b""
    assert m.get_messages(4) == []


def test_fixed64_wire_is_little_endian():
    data = Writer().fixed64(1, 1).build()
    # ключ (1<<3)|1 = 0x09, затем 8 байт LE
    assert data == b"\x09" + struct.pack("<Q", 1)
