#!/usr/bin/env python3
"""Build a DreamView `0x50` group-membership upload for an *emulated* follower.

Why this exists: the Govee TV backlight controller ("sync centre") finds its
DreamView followers by BLE identity (reversed MAC, or UTF-8 BLE name), then
connects out to each one and writes live colours into it. To capture those
live colours we stand up a fake Govee-light peripheral (see
GoveeDreamViewReceiver.swift) and enrol it in the group with a record like this
one, addressed by the name we advertise.

Wire layout is transcribed from the public reverse-engineered spec
teh-hippo/ha-govee-led-ble @ b845c59, tools/ble/kaitai/speculative/
h6099_dreamview_group.ksy, and the A3 framing in
custom_components/ha_govee_led_ble/transport.py. It is a candidate, not a
hardware-confirmed packet: cmd_ver must be supplied from real device evidence,
never guessed (the upstream schema says so explicitly).

Stdlib only. Run the self-check with:  python3 -I build_member_record.py
"""
from __future__ import annotations

import math

A3_CHUNK_SIZE = 17
GROUP_TYPE = 0x50  # h6099_dreamview_group.ksy instances.group_type


def xor_checksum(data: bytes) -> int:
    c = 0
    for b in data:
        c ^= b
    return c


def _a3_frame(index: int, chunk: bytes) -> bytes:
    # Mirrors transport._a3_frame: a3 | index | <=17 chunk, right-padded to 19, XOR trailer.
    packet = bytearray([0xA3, index, *chunk])
    packet = (packet + bytearray(19 - len(packet)))[:19]
    packet.append(xor_checksum(packet))
    return bytes(packet)


def fragment_a3(type_byte: int, body: bytes, *, terminator: bool = False) -> list[bytes]:
    # Faithful copy of transport.fragment_a3 so emitted packets match the real client byte-for-byte.
    data = bytes([type_byte]) + body
    chunk_count = math.ceil((len(data) + 2) / A3_CHUNK_SIZE)
    trailing = terminator or chunk_count == 1
    payload = bytes([0x01, chunk_count + (1 if trailing else 0)]) + data
    chunks = [payload[i : i + A3_CHUNK_SIZE] for i in range(0, len(payload), A3_CHUNK_SIZE)]
    last = len(chunks) - 1
    packets = [
        _a3_frame(i if trailing or i != last else 0xFF, chunk) for i, chunk in enumerate(chunks)
    ]
    if trailing:
        packets.append(_a3_frame(0xFF, b""))
    return packets


def _area_byte(area: int) -> int:
    # ponytail: wire areas are 1..10, 0=unassigned, 0xff=disabled. The UI's 1..20 maps to 1..10;
    # callers pass wire values directly so this stays a validator, not a second mapping table.
    if area not in (*range(11), 0xFF):
        raise ValueError("area must be wire 1..10, 0 (unassigned), or 0xff (disabled)")
    return area


def member_record(*, is_rgbic: bool, cmd_ver: int, areas: tuple[int, ...],
                   name: str | None = None, mac: str | None = None) -> bytes:
    """One member record. Supply exactly one of name / mac. MAC is display order; it is reversed here."""
    if (name is None) == (mac is None):
        raise ValueError("supply exactly one of name or mac")
    if not 0 <= cmd_ver <= 255:
        raise ValueError("cmd_ver out of range")
    if not 1 <= len(areas) <= 255:
        raise ValueError("supply 1..255 areas")
    rec = bytearray([1 if is_rgbic else 0])
    if mac is not None:
        octets = bytes(int(p, 16) for p in mac.split(":"))
        if len(octets) != 6:
            raise ValueError("MAC must be 6 colon-separated hex octets")
        rec += bytes([0x00, cmd_ver]) + octets[::-1]  # identity_kind=mac, reversed display order
    else:
        encoded = name.encode("utf-8")
        if not 1 <= len(encoded) <= 255:
            raise ValueError("name must encode to 1..255 UTF-8 bytes")
        rec += bytes([0x01, cmd_ver, len(encoded)]) + encoded  # identity_kind=name
    rec.append(len(areas))
    rec += bytes(_area_byte(a) for a in areas)
    return bytes(rec)


def build_group_upload(members: list[bytes]) -> tuple[bytes, list[bytes]]:
    """Return (raw group body, A3 0x50 frames ready to write to the sync centre's WRITE characteristic)."""
    if not 1 <= len(members) <= 255:
        raise ValueError("1..255 members")
    body = bytes([len(members)]) + b"".join(members)
    return body, fragment_a3(GROUP_TYPE, body)


def demo() -> None:
    # XOR trailer: hand-checked tiny frame.
    assert xor_checksum(b"\xa3\x00\x01\x02") == (0xA3 ^ 0x00 ^ 0x01 ^ 0x02)

    # A single-chunk A3 body produces a data frame (index 0) + terminator frame (index 0xff),
    # each exactly 20 bytes with a valid XOR trailer -- the shape transport.reassemble_a3 accepts.
    frames = fragment_a3(GROUP_TYPE, b"\x00")
    assert len(frames) == 2
    assert all(len(f) == 20 for f in frames)
    assert frames[0][0] == 0xA3 and frames[0][1] == 0x00
    assert frames[-1][1] == 0xFF
    assert all(xor_checksum(f[:19]) == f[19] for f in frames)
    # envelope marker 0x01 and declared frame count == number of frames (reassemble_a3's invariant)
    assert frames[0][2] == 0x01 and frames[0][3] == len(frames)

    # A name-addressed RGBIC member on areas 1 and 2 round-trips through the record layout.
    rec = member_record(is_rgbic=True, cmd_ver=1, areas=(1, 2), name="Luma-Bridge")
    assert rec[0] == 1 and rec[1] == 0x01 and rec[2] == 1  # is_rgbic, identity_kind=name, cmd_ver
    assert rec[3] == len(b"Luma-Bridge")
    assert rec.endswith(bytes([2, 1, 2]))  # area_count=2, areas 1,2

    # A MAC-addressed member reverses display order.
    rec_mac = member_record(is_rgbic=False, cmd_ver=2, areas=(0xFF,), mac="AA:BB:CC:DD:EE:FF")
    assert rec_mac[:3] == bytes([0, 0x00, 2])  # is_rgbic=0, identity_kind=mac, cmd_ver=2
    assert rec_mac[3:9] == bytes([0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA])

    body, group_frames = build_group_upload([rec])
    assert body[0] == 1  # one member
    assert body[1:] == rec
    assert all(len(f) == 20 and xor_checksum(f[:19]) == f[19] for f in group_frames)
    print("ok:", len(group_frames), "A3 frames for 1 member;",
          "group body", body.hex())


if __name__ == "__main__":
    demo()
