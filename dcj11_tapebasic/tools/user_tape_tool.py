#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import struct
from dataclasses import dataclass
from pathlib import Path

SECTOR_SIZE = 512
CARD_MAGIC = b"DCJTBAS\0"
USER_MAGIC = b"DCJPTAPE"
VERSION = 1


@dataclass
class CardHeader:
    magic: bytes
    version: int
    boot_start_lba: int
    boot_byte_length: int
    user_meta_lba: int
    user_data_lba: int
    flags: int


@dataclass
class UserMetadata:
    magic: bytes
    version: int
    valid: int
    byte_length: int
    sequence: int
    flags: int


def is_device_path(path: Path) -> bool:
    return str(path).startswith("/dev/")


def require_device_ack(path: Path, device: bool) -> None:
    if is_device_path(path) and not device:
        raise SystemExit("refusing to write a /dev path without --device")


def read_at(path: Path, offset: int, size: int) -> bytes:
    with path.open("rb") as f:
        f.seek(offset)
        data = f.read(size)
    return data + bytes(size - len(data))


def write_at(path: Path, offset: int, data: bytes) -> None:
    with path.open("r+b") as f:
        f.seek(offset)
        f.write(data)
        f.flush()
        os.fsync(f.fileno())


def parse_header(sector: bytes) -> CardHeader:
    version, boot_start, boot_len, user_meta, user_data, flags = struct.unpack_from("<IIIIII", sector, 8)
    return CardHeader(sector[0:8], version, boot_start, boot_len, user_meta, user_data, flags)


def parse_user_meta(sector: bytes) -> UserMetadata:
    version, valid, byte_len, sequence, flags = struct.unpack_from("<IIIII", sector, 8)
    return UserMetadata(sector[0:8], version, valid, byte_len, sequence, flags)


def user_meta_sector(meta: UserMetadata) -> bytes:
    sector = bytearray(SECTOR_SIZE)
    sector[0:8] = USER_MAGIC
    struct.pack_into("<IIIII", sector, 8, VERSION, meta.valid, meta.byte_length, meta.sequence, meta.flags)
    return bytes(sector)


def load_header(path: Path) -> CardHeader:
    return parse_header(read_at(path, 0, SECTOR_SIZE))


def load_user_meta(path: Path, header: CardHeader) -> UserMetadata:
    return parse_user_meta(read_at(path, header.user_meta_lba * SECTOR_SIZE, SECTOR_SIZE))


def print_header(header: CardHeader) -> None:
    print(f"magic={header.magic!r}")
    print(f"version={header.version}")
    print(f"boot_start_lba={header.boot_start_lba}")
    print(f"boot_byte_length={header.boot_byte_length}")
    print(f"user_meta_lba={header.user_meta_lba}")
    print(f"user_data_lba={header.user_data_lba}")
    print(f"flags=0x{header.flags:08x}")


def print_user_meta(meta: UserMetadata) -> None:
    print(f"magic={meta.magic!r}")
    print(f"version={meta.version}")
    print(f"valid={meta.valid}")
    print(f"byte_length={meta.byte_length}")
    print(f"sequence={meta.sequence}")
    print(f"flags=0x{meta.flags:08x}")


def ensure_layout(header: CardHeader) -> None:
    if header.magic != CARD_MAGIC or header.version != VERSION:
        raise SystemExit("not a dcj11tapebasic SD image")
    boot_end = header.boot_start_lba + (header.boot_byte_length + SECTOR_SIZE - 1) // SECTOR_SIZE
    if header.user_meta_lba < boot_end or header.user_data_lba <= header.user_meta_lba:
        raise SystemExit("layout would overlap boot tape")


def command_dump_header(args: argparse.Namespace) -> int:
    print_header(load_header(args.image))
    return 0


def command_dump_user(args: argparse.Namespace) -> int:
    header = load_header(args.image)
    ensure_layout(header)
    print_user_meta(load_user_meta(args.image, header))
    return 0


def command_extract_user(args: argparse.Namespace) -> int:
    header = load_header(args.image)
    ensure_layout(header)
    meta = load_user_meta(args.image, header)
    if meta.magic != USER_MAGIC or meta.version != VERSION or meta.valid != 1:
        raise SystemExit("user tape is not valid")
    data = read_at(args.image, header.user_data_lba * SECTOR_SIZE, meta.byte_length)
    args.out.write_bytes(data)
    print(f"wrote {len(data)} bytes to {args.out}")
    return 0


def command_write_user(args: argparse.Namespace) -> int:
    require_device_ack(args.image, args.device)
    header = load_header(args.image)
    ensure_layout(header)
    old = load_user_meta(args.image, header)
    sequence = args.sequence if args.sequence is not None else old.sequence + 1
    data = args.input.read_bytes()
    padded = data + bytes((-len(data)) % SECTOR_SIZE)
    write_at(args.image, header.user_data_lba * SECTOR_SIZE, padded)
    meta = UserMetadata(USER_MAGIC, VERSION, 1, len(data), sequence & 0xFFFFFFFF, 0)
    write_at(args.image, header.user_meta_lba * SECTOR_SIZE, user_meta_sector(meta))
    print(f"stored {len(data)} bytes, sequence={meta.sequence}")
    return 0


def command_clear_user(args: argparse.Namespace) -> int:
    require_device_ack(args.image, args.device)
    header = load_header(args.image)
    ensure_layout(header)
    old = load_user_meta(args.image, header)
    sequence = args.sequence if args.sequence is not None else old.sequence + 1
    meta = UserMetadata(USER_MAGIC, VERSION, 0, 0, sequence & 0xFFFFFFFF, 0)
    write_at(args.image, header.user_meta_lba * SECTOR_SIZE, user_meta_sector(meta))
    print(f"cleared user tape, sequence={meta.sequence}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect or update dcj11tapebasic raw user paper tape.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("dump-header")
    p.add_argument("image", type=Path)
    p.set_defaults(func=command_dump_header)

    p = sub.add_parser("dump-user")
    p.add_argument("image", type=Path)
    p.set_defaults(func=command_dump_user)

    p = sub.add_parser("extract-user")
    p.add_argument("image", type=Path)
    p.add_argument("--out", type=Path, required=True)
    p.set_defaults(func=command_extract_user)

    p = sub.add_parser("write-user")
    p.add_argument("image", type=Path)
    p.add_argument("--in", dest="input", type=Path, required=True)
    p.add_argument("--sequence", type=int)
    p.add_argument("--device", action="store_true")
    p.set_defaults(func=command_write_user)

    p = sub.add_parser("clear-user")
    p.add_argument("image", type=Path)
    p.add_argument("--sequence", type=int)
    p.add_argument("--device", action="store_true")
    p.set_defaults(func=command_clear_user)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
