#!/usr/bin/env python3
"""Compile PyroWave shaders into reviewable, checked-in SPIR-V headers."""
import argparse
import pathlib
import struct
import subprocess
import tempfile


def main():
    """Compile each source/symbol pair without shell interpolation."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--compiler", default="glslc")
    parser.add_argument("--shader", nargs=2, action="append", required=True,
                        metavar=("SOURCE", "SYMBOL"))
    args = parser.parse_args()
    text = (
        "/**\n * @file " + args.output.name +
        "\n * @brief Generated SPIR-V; regenerate with "
        "tools/pyrowave/generate_shaders.py.\n */\n"
        "#pragma once\n#include <cstdint>\n")
    with tempfile.TemporaryDirectory(prefix="pyrowave-shaders-") as directory:
        for index, (source, symbol) in enumerate(args.shader):
            if not symbol.isidentifier() or not symbol.isascii():
                raise ValueError("Shader symbol must be an ASCII identifier")
            binary = pathlib.Path(directory) / (str(index) + ".spv")
            subprocess.run([args.compiler, source, "-o", str(binary)],
                           check=True)
            data = binary.read_bytes()
            words = struct.unpack("<" + "I" * (len(data) // 4), data)
            text += (
                "/**\n * @brief Compiled " + pathlib.Path(source).name +
                " shader.\n */\n// clang-format off\nstatic const uint32_t " +
                symbol + "[] = {\n")
            rows = [", ".join(map(hex, words[start:start + 8]))
                    for start in range(0, len(words), 8)]
            text += "\n".join("  " + row + "," for row in rows)
            text += "\n};\n// clang-format on\n"
    args.output.write_text(text)


if __name__ == "__main__":
    main()
