#!/usr/bin/env python3
"""@file
@brief Extract a type-2 x86_64 AppImage without executing its FUSE runtime.
"""

from pathlib import Path
import struct
import subprocess
import sys


def squashfs_offset(data):
    """@brief Locate SquashFS immediately following the ELF runtime.
    @param data Complete AppImage bytes.
    @return Validated SquashFS offset.
    @throws ValueError When the image format or section table is invalid.
    """
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("Expected a little-endian ELF64 AppImage")
    if data[8:11] != b"AI\x02":
        raise ValueError("Expected a type-2 AppImage")
    header = struct.unpack_from("<16sHHIQQQIHHHHHH", data)
    table, entry_size, count = header[6], header[11], header[12]
    if header[2] != 62 or entry_size != 64 or not count:
        raise ValueError("Unsupported ELF architecture or section table")
    end = table + entry_size * count
    if table < 64 or end > len(data):
        raise ValueError("Truncated ELF section table")
    for index in range(count):
        section = struct.unpack_from(
            "<IIQQQQIIQQ", data, table + index * entry_size
        )
        # SHT_NOBITS occupies memory only and contributes no bytes to the file.
        if section[1] != 8:
            end = max(end, section[4] + section[5])
    magic_end = end + 4
    if data[end:magic_end] != b"hsqs":
        raise ValueError("Missing SquashFS payload after ELF runtime")
    return end


def main():
    """@brief Extract a verified image into a new destination directory."""
    if len(sys.argv) != 3:
        raise ValueError("Usage: extract.py IMAGE DESTINATION")
    image, destination = map(Path, sys.argv[1:])
    if destination.exists():
        raise ValueError("Extraction destination already exists")
    offset = squashfs_offset(image.read_bytes())
    subprocess.run(
        [
            "unsquashfs",
            "-no-progress",
            "-o",
            str(offset),
            "-d",
            str(destination),
            str(image),
        ],
        check=True,
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
