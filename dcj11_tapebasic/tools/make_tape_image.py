#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
from pathlib import Path

DEFAULT_SKIP_BYTES = 16
DEFAULT_PAD_BYTES = 512
SECTOR_SIZE = 512
CARD_MAGIC = b"DCJTBAS\0"
USER_MAGIC = b"DCJPTAPE"
VERSION = 1
BOOT_START_LBA = 1


def read_concat_ptaps(paths: list[Path], skip: int) -> bytes:
    raw = b"".join(path.read_bytes() for path in paths)
    if skip < 0:
        raise ValueError("skip must be non-negative")
    if skip > len(raw):
        raise ValueError(f"skip={skip} is larger than concatenated input length={len(raw)}")
    return raw[skip:]


def pad_to_block(data: bytes, block_size: int) -> bytes:
    if block_size <= 0:
        return data
    padding = (-len(data)) % block_size
    return data + bytes(padding)


def card_header(boot_bytes: int, user_meta_lba: int, user_data_lba: int) -> bytes:
    sector = bytearray(SECTOR_SIZE)
    sector[0:8] = CARD_MAGIC
    struct.pack_into(
        "<IIIIII",
        sector,
        8,
        VERSION,
        BOOT_START_LBA,
        boot_bytes,
        user_meta_lba,
        user_data_lba,
        0,
    )
    return bytes(sector)


def user_metadata(valid: int = 0, byte_length: int = 0, sequence: int = 0, flags: int = 0) -> bytes:
    sector = bytearray(SECTOR_SIZE)
    sector[0:8] = USER_MAGIC
    struct.pack_into("<IIIII", sector, 8, VERSION, valid, byte_length, sequence, flags)
    return bytes(sector)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build a raw SD image for dcj11tapebasic SD boot tape plus one user tape."
    )
    parser.add_argument(
        "--reference-dat",
        type=Path,
        help="Use an already built tapeimage.dat, such as the TangNanoDCJ11MEM reference file.",
    )
    parser.add_argument(
        "--ptap",
        type=Path,
        action="append",
        default=[],
        help="Input .ptap file. Pass absolute loader first, then Paper Tape BASIC.",
    )
    parser.add_argument(
        "--skip",
        type=int,
        default=DEFAULT_SKIP_BYTES,
        help="Bytes to skip from the concatenated .ptap stream. Default matches the reference README.",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "testdata",
    )
    parser.add_argument("--tape-name", default="tapeimage.dat")
    parser.add_argument("--sd-name", default="dcj11tapebasic_sd.img")
    parser.add_argument("--pad", type=int, default=DEFAULT_PAD_BYTES)
    parser.add_argument(
        "--user-bytes",
        type=int,
        default=1024 * 1024,
        help="Blank user data area bytes to append after user metadata.",
    )
    args = parser.parse_args()

    if args.reference_dat and args.ptap:
        parser.error("--reference-dat and --ptap are mutually exclusive")
    if not args.reference_dat and not args.ptap:
        parser.error("pass --reference-dat or two --ptap inputs")

    if args.reference_dat:
        tape = args.reference_dat.read_bytes()
    else:
        tape = read_concat_ptaps(args.ptap, args.skip)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    tape_path = args.out_dir / args.tape_name
    sd_path = args.out_dir / args.sd_name
    tape_path.write_bytes(tape)

    boot_area = pad_to_block(tape, args.pad)
    boot_sectors = len(boot_area) // SECTOR_SIZE
    user_meta_lba = BOOT_START_LBA + boot_sectors
    user_data_lba = user_meta_lba + 1
    image = (
        card_header(len(tape), user_meta_lba, user_data_lba)
        + boot_area
        + user_metadata()
        + bytes(args.user_bytes)
    )
    sd_path.write_bytes(image)

    manifest = (
        "dcj11tapebasic SD boot plus user tape image\n"
        f"tape_file={tape_path.name}\n"
        f"sd_file={sd_path.name}\n"
        f"tape_bytes={len(tape)}\n"
        f"sd_bytes={sd_path.stat().st_size}\n"
        f"boot_start_lba={BOOT_START_LBA}\n"
        f"boot_byte_length={len(tape)}\n"
        f"user_meta_lba={user_meta_lba}\n"
        f"user_data_lba={user_data_lba}\n"
        "checksums=none\n"
    )
    (args.out_dir / "manifest.txt").write_text(manifest, encoding="utf-8")
    print(manifest, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
