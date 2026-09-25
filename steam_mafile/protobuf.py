"""Минимальный кодек protobuf — ровно столько, сколько нужно для IAuthenticationService.

Чтобы не тащить скомпилированные .proto, сообщения собираются руками по номерам полей
(см. SteamDatabase/Protobufs, steammessages_auth.steamclient.proto).
"""

import struct

WIRE_VARINT = 0
WIRE_FIXED64 = 1
WIRE_LEN = 2
WIRE_FIXED32 = 5


def encode_varint(value: int) -> bytes:
    if value < 0:  # int32/int64 с минусом кодируются как 64-битное дополнение до двух
        value += 1 << 64
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def decode_varint(data: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if pos >= len(data):
            raise ValueError("обрезанный varint")
        byte = data[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift >= 64:
            raise ValueError("слишком длинный varint")


class Writer:
    def __init__(self):
        self._buf = bytearray()

    def _key(self, field: int, wire: int):
        self._buf += encode_varint((field << 3) | wire)

    def varint(self, field: int, value: int) -> "Writer":
        self._key(field, WIRE_VARINT)
        self._buf += encode_varint(int(value))
        return self

    def bool(self, field: int, value: bool) -> "Writer":
        return self.varint(field, 1 if value else 0)

    def fixed64(self, field: int, value: int) -> "Writer":
        self._key(field, WIRE_FIXED64)
        self._buf += struct.pack("<Q", int(value))
        return self

    def bytes(self, field: int, value: bytes) -> "Writer":
        self._key(field, WIRE_LEN)
        self._buf += encode_varint(len(value))
        self._buf += value
        return self

    def string(self, field: int, value: str) -> "Writer":
        return self.bytes(field, value.encode("utf-8"))

    def message(self, field: int, value: "Writer") -> "Writer":
        return self.bytes(field, value.build())

    def build(self) -> bytes:
        return bytes(self._buf)


class Message:
    """Разобранное сообщение: номер поля -> список сырых значений.

    varint и fixed64 хранятся как int, length-delimited и fixed32 — как bytes.
    """

    def __init__(self, data: bytes):
        self.fields: dict[int, list] = {}
        pos = 0
        while pos < len(data):
            key, pos = decode_varint(data, pos)
            field, wire = key >> 3, key & 7
            if wire == WIRE_VARINT:
                value, pos = decode_varint(data, pos)
            elif wire == WIRE_FIXED64:
                value = struct.unpack_from("<Q", data, pos)[0]
                pos += 8
            elif wire == WIRE_LEN:
                length, pos = decode_varint(data, pos)
                value = data[pos:pos + length]
                if len(value) != length:
                    raise ValueError("обрезанное поле")
                pos += length
            elif wire == WIRE_FIXED32:
                value = data[pos:pos + 4]
                pos += 4
            else:
                raise ValueError(f"неподдерживаемый wire type {wire}")
            self.fields.setdefault(field, []).append(value)

    def get_int(self, field: int, default: int = 0) -> int:
        values = self.fields.get(field)
        return values[-1] if values else default

    def get_bytes(self, field: int, default: bytes = b"") -> bytes:
        values = self.fields.get(field)
        return values[-1] if values else default

    def get_str(self, field: int, default: str = "") -> str:
        values = self.fields.get(field)
        return values[-1].decode("utf-8") if values else default

    def get_float(self, field: int, default: float = 0.0) -> float:
        values = self.fields.get(field)
        return struct.unpack("<f", values[-1])[0] if values else default

    def get_messages(self, field: int) -> list["Message"]:
        return [Message(v) for v in self.fields.get(field, [])]
