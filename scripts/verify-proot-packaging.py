#!/usr/bin/env python3
"""Fail-closed validation for ClawChat PRoot source and APK payloads."""

from __future__ import annotations

import argparse
from collections import Counter
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import subprocess
import sys
import zipfile


SUPPORTED_ABIS = {
    "arm64-v8a": {
        "libproot.so": (2, 183),
        "libprootloader.so": (2, 183),
        "libprootloader32.so": (1, 40),
        "libtalloc.so": (2, 183),
    },
    "armeabi-v7a": {
        "libproot.so": (1, 40),
        "libprootloader.so": (1, 40),
        "libtalloc.so": (1, 40),
    },
    "x86_64": {
        "libproot.so": (2, 62),
        "libprootloader.so": (2, 62),
        "libprootloader32.so": (1, 3),
        "libtalloc.so": (2, 62),
    },
}

ARTIFACT_MODES = ("source", "universal", "split")

MIN_ELF_SIZE = 4096
ANDROID_16K_PAGE_SIZE = 16384

ET_EXEC = 2
ET_DYN = 3
PT_LOAD = 1
PT_DYNAMIC = 2
PT_INTERP = 3
PF_X = 1
DT_NULL = 0
DT_NEEDED = 1
DT_STRTAB = 5
DT_STRSZ = 10
DT_SONAME = 14

UNSAFE_ZIP_FILE_TYPES = {
    stat.S_IFLNK,
    stat.S_IFIFO,
    stat.S_IFSOCK,
    stat.S_IFBLK,
    stat.S_IFCHR,
}


class VerificationError(Exception):
    """The payload cannot be proven safe to publish."""


def _bounded_end(offset: int, size: int, limit: int, label: str) -> int:
    if offset < 0 or size < 0 or offset > limit or size > limit - offset:
        raise VerificationError(f"{label}: range exceeds file size")
    return offset + size


def _bounded_address_end(address: int, size: int, bits: int, label: str) -> int:
    address_limit = 1 << bits
    if address < 0 or size < 0 or address >= address_limit:
        raise VerificationError(f"{label}: invalid virtual-address range")
    if size > address_limit - address:
        raise VerificationError(f"{label}: virtual-address range overflows ELF class")
    return address + size


def _expected_payloads(abis: set[str]) -> tuple[tuple[str, str], ...]:
    """Return the one canonical ABI/name matrix used by every verifier lane."""
    unsupported = abis - set(SUPPORTED_ABIS)
    if unsupported:
        raise VerificationError(f"unsupported PRoot ABI set: {sorted(unsupported)}")
    return tuple(
        (abi, name)
        for abi in SUPPORTED_ABIS
        if abi in abis
        for name in SUPPORTED_ABIS[abi]
    )


def _read_c_string(data: bytes, offset: int, size: int, label: str) -> str:
    end_limit = _bounded_end(offset, size, len(data), label)
    if size == 0:
        raise VerificationError(f"{label}: empty ELF string range")
    end = data.find(b"\0", offset, end_limit)
    if end < 0:
        raise VerificationError(f"{label}: unterminated ELF string")
    try:
        return data[offset:end].decode("ascii", errors="strict")
    except UnicodeDecodeError as error:
        raise VerificationError(f"{label}: non-ASCII ELF string") from error


def _parse_elf(data: bytes, label: str) -> dict[str, object]:
    if len(data) < 16 or data[:4] != b"\x7fELF":
        raise VerificationError(f"{label}: not an ELF binary")
    elf_class = data[4]
    if elf_class not in (1, 2) or data[5] != 1 or data[6] != 1:
        raise VerificationError(f"{label}: unsupported ELF class, byte order, or version")

    header_size = 52 if elf_class == 1 else 64
    if len(data) < header_size:
        raise VerificationError(f"{label}: truncated ELF header")
    if elf_class == 1:
        header = struct.unpack_from("<HHIIIIIHHHHHH", data, 16)
        elf_type, machine, elf_version, entry, phoff = header[:5]
        ehsize, phentsize, phnum = header[7:10]
        ph_format = "<IIIIIIII"
        dynamic_format = "<II"
    else:
        header = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
        elf_type, machine, elf_version, entry, phoff = header[:5]
        ehsize, phentsize, phnum = header[7:10]
        ph_format = "<IIQQQQQQ"
        dynamic_format = "<QQ"

    expected_phentsize = struct.calcsize(ph_format)
    if elf_version != 1 or ehsize != header_size:
        raise VerificationError(f"{label}: malformed ELF header")
    if phnum == 0:
        raise VerificationError(f"{label}: ELF has no program headers")
    if phentsize != expected_phentsize:
        raise VerificationError(f"{label}: malformed ELF program-header size")
    if phoff > len(data) or phnum > (len(data) - phoff) // phentsize:
        raise VerificationError(f"{label}: program-header table exceeds file size")

    address_bits = 32 if elf_class == 1 else 64
    loads: list[dict[str, int]] = []
    dynamic: dict[str, int] | None = None
    interpreter: str | None = None
    for index in range(phnum):
        offset = phoff + index * phentsize
        values = struct.unpack_from(ph_format, data, offset)
        if elf_class == 1:
            p_type, p_offset, p_vaddr, _, p_filesz, p_memsz, p_flags, p_align = values
        else:
            p_type, p_flags, p_offset, p_vaddr, _, p_filesz, p_memsz, p_align = values

        if p_filesz > p_memsz:
            raise VerificationError(
                f"{label}: program header {index} has p_filesz greater than p_memsz"
            )
        _bounded_end(p_offset, p_filesz, len(data), f"{label}: program header {index}")
        _bounded_address_end(
            p_vaddr,
            p_memsz,
            address_bits,
            f"{label}: program header {index}",
        )

        if p_type == PT_LOAD:
            if p_memsz == 0:
                raise VerificationError(f"{label}: PT_LOAD {index} has zero size")
            if p_align == 0 or p_align & (p_align - 1):
                raise VerificationError(
                    f"{label}: PT_LOAD {index} alignment is not a nonzero power of two"
                )
            if p_offset % p_align != p_vaddr % p_align:
                raise VerificationError(
                    f"{label}: PT_LOAD {index} offset/address alignment is incongruent"
                )
            if elf_class == 2 and p_align < ANDROID_16K_PAGE_SIZE:
                raise VerificationError(
                    f"{label}: PT_LOAD {index} is not compatible with 16 KiB Android pages"
                )
            loads.append(
                {
                    "vaddr": p_vaddr,
                    "offset": p_offset,
                    "filesz": p_filesz,
                    "memsz": p_memsz,
                    "flags": p_flags,
                    "align": p_align,
                }
            )
        elif p_type == PT_DYNAMIC:
            if dynamic is not None:
                raise VerificationError(f"{label}: multiple PT_DYNAMIC segments")
            dynamic = {
                "vaddr": p_vaddr,
                "offset": p_offset,
                "filesz": p_filesz,
            }
        elif p_type == PT_INTERP:
            if interpreter is not None:
                raise VerificationError(f"{label}: multiple PT_INTERP segments")
            interpreter = _read_c_string(
                data, p_offset, p_filesz, f"{label}: PT_INTERP"
            )

    if not loads:
        raise VerificationError(f"{label}: ELF has no PT_LOAD segment")

    def range_is_file_backed(address: int, offset: int, size: int) -> bool:
        for load in loads:
            if address < load["vaddr"] or offset < load["offset"]:
                continue
            address_delta = address - load["vaddr"]
            offset_delta = offset - load["offset"]
            if address_delta != offset_delta:
                continue
            if size <= load["filesz"] and address_delta <= load["filesz"] - size:
                return True
        return False

    if dynamic is not None and not range_is_file_backed(
        dynamic["vaddr"], dynamic["offset"], dynamic["filesz"]
    ):
        raise VerificationError(f"{label}: PT_DYNAMIC is not file-backed by PT_LOAD")

    def virtual_range_to_file(address: int, size: int) -> int:
        for load in loads:
            vaddr = load["vaddr"]
            filesz = load["filesz"]
            if address >= vaddr and size <= filesz and address - vaddr <= filesz - size:
                return load["offset"] + address - vaddr
        raise VerificationError(f"{label}: dynamic string table is not file-backed")

    needed_offsets: list[int] = []
    soname_offsets: list[int] = []
    string_addresses: list[int] = []
    string_sizes: list[int] = []
    if dynamic is not None:
        dynamic_offset = dynamic["offset"]
        dynamic_size = dynamic["filesz"]
        entry_size = struct.calcsize(dynamic_format)
        if dynamic_size == 0 or dynamic_size % entry_size != 0:
            raise VerificationError(f"{label}: malformed dynamic table")
        terminated = False
        for offset in range(dynamic_offset, dynamic_offset + dynamic_size, entry_size):
            tag, value = struct.unpack_from(dynamic_format, data, offset)
            if tag == DT_NULL:
                terminated = True
                break
            if tag == DT_NEEDED:
                needed_offsets.append(value)
            elif tag == DT_STRTAB:
                string_addresses.append(value)
            elif tag == DT_STRSZ:
                string_sizes.append(value)
            elif tag == DT_SONAME:
                soname_offsets.append(value)
        if not terminated:
            raise VerificationError(f"{label}: dynamic table has no DT_NULL terminator")

    needed: list[str] = []
    soname: str | None = None
    string_references = [*needed_offsets, *soname_offsets]
    if string_references:
        if len(string_addresses) != 1 or len(string_sizes) != 1:
            raise VerificationError(f"{label}: incomplete or ambiguous dynamic string table")
        string_size = string_sizes[0]
        if string_size == 0:
            raise VerificationError(f"{label}: empty dynamic string table")
        table_offset = virtual_range_to_file(string_addresses[0], string_size)
        for string_offset in string_references:
            if string_offset >= string_size:
                raise VerificationError(f"{label}: dynamic string offset exceeds table")
        needed = [
            _read_c_string(
                data,
                table_offset + string_offset,
                string_size - string_offset,
                f"{label}: DT_NEEDED",
            )
            for string_offset in needed_offsets
        ]
        if len(soname_offsets) > 1:
            raise VerificationError(f"{label}: multiple DT_SONAME entries")
        if soname_offsets:
            string_offset = soname_offsets[0]
            soname = _read_c_string(
                data,
                table_offset + string_offset,
                string_size - string_offset,
                f"{label}: DT_SONAME",
            )

    entry_in_executable_load = any(
        load["flags"] & PF_X
        and entry >= load["vaddr"]
        and entry - load["vaddr"] < load["filesz"]
        for load in loads
    )
    return {
        "class": elf_class,
        "machine": machine,
        "type": elf_type,
        "entry": entry,
        "entry_in_executable_load": entry_in_executable_load,
        "interpreter": interpreter,
        "needed": needed,
        "soname": soname,
        "has_dynamic": dynamic is not None,
    }


def _verify_elf(data: bytes, abi: str, name: str, label: str) -> None:
    parsed = _parse_elf(data, label)
    expected_class, expected_machine = SUPPORTED_ABIS[abi][name]
    if (parsed["class"], parsed["machine"]) != (expected_class, expected_machine):
        raise VerificationError(
            f"{label}: wrong ELF ABI (class={parsed['class']}, machine={parsed['machine']})"
        )

    if name == "libproot.so":
        expected_interpreter = (
            "/system/bin/linker64" if expected_class == 2 else "/system/bin/linker"
        )
        if parsed["type"] != ET_DYN or parsed["entry"] == 0:
            raise VerificationError(f"{label}: PRoot is not an executable PIE")
        if not parsed["entry_in_executable_load"]:
            raise VerificationError(
                f"{label}: PRoot entry is outside executable file-backed PT_LOAD segments"
            )
        if parsed["interpreter"] != expected_interpreter:
            raise VerificationError(
                f"{label}: unexpected interpreter {parsed['interpreter']!r}"
            )
        if Counter(parsed["needed"]) != Counter(("libtalloc.so.2", "libc.so")):
            raise VerificationError(
                f"{label}: unexpected dependencies {parsed['needed']!r}"
            )
    elif name == "libtalloc.so":
        if parsed["type"] != ET_DYN or parsed["soname"] != "libtalloc.so.2":
            raise VerificationError(f"{label}: invalid libtalloc SONAME")
        if parsed["interpreter"] is not None:
            raise VerificationError(f"{label}: libtalloc must not contain PT_INTERP")
        if Counter(parsed["needed"]) != Counter(("libc.so",)):
            raise VerificationError(
                f"{label}: unexpected dependencies {parsed['needed']!r}"
            )
    else:
        if parsed["type"] != ET_EXEC or parsed["interpreter"] is not None:
            raise VerificationError(f"{label}: PRoot loader is not static ET_EXEC")
        if parsed["has_dynamic"] or parsed["needed"]:
            raise VerificationError(f"{label}: PRoot loader is not fully static")
        if parsed["entry"] == 0:
            raise VerificationError(f"{label}: static loader has a zero entry point")
        if not parsed["entry_in_executable_load"]:
            raise VerificationError(
                f"{label}: static loader entry is outside executable PT_LOAD segments"
            )


def _verify_file(path: Path, abi: str, name: str, *, require_executable: bool) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise VerificationError(f"missing {path}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise VerificationError(f"{path}: expected a regular file, not a symlink/device")
    if require_executable and mode & 0o111 == 0:
        raise VerificationError(f"{path}: source payload is not executable")
    data = path.read_bytes()
    if len(data) < MIN_ELF_SIZE:
        raise VerificationError(
            f"{path}: payload is too small ({len(data)} bytes; minimum {MIN_ELF_SIZE})"
        )
    _verify_elf(data, abi, name, str(path))


def _regular_directory(path: Path, label: str) -> Path:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise VerificationError(f"missing {label}: {path}") from error
    if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
        raise VerificationError(f"{label} is not a real directory: {path}")
    return path.resolve(strict=True)


def verify_jni_dir(jni_dir: Path) -> None:
    root = _regular_directory(jni_dir, "jniLibs directory")
    actual_abis = {entry.name for entry in jni_dir.iterdir()}
    expected_abis = set(SUPPORTED_ABIS)
    if actual_abis != expected_abis:
        raise VerificationError(
            f"{jni_dir}: ABI directories must be exactly {sorted(expected_abis)}; "
            f"found {sorted(actual_abis)}"
        )

    expected_payloads = _expected_payloads(expected_abis)
    for abi in SUPPORTED_ABIS:
        abi_dir = jni_dir / abi
        resolved_abi = _regular_directory(abi_dir, f"ABI directory {abi}")
        try:
            resolved_abi.relative_to(root)
        except ValueError as error:
            raise VerificationError(f"{abi_dir}: ABI directory escapes jniLibs") from error
        actual_names = {entry.name for entry in abi_dir.iterdir()}
        expected_names = {
            name for payload_abi, name in expected_payloads if payload_abi == abi
        }
        if actual_names != expected_names:
            raise VerificationError(
                f"{abi_dir}: files must be exactly {sorted(expected_names)}; "
                f"found {sorted(actual_names)}"
            )
        for name in sorted(expected_names):
            path = abi_dir / name
            if stat.S_ISLNK(path.lstat().st_mode):
                raise VerificationError(f"{path}: expected a regular file, not a symlink")
            try:
                path.resolve(strict=True).relative_to(resolved_abi)
            except ValueError as error:
                raise VerificationError(f"{path}: payload escapes ABI directory") from error
            _verify_file(path, abi, name, require_executable=True)
    print(f"PASS: verified exact 11-file PRoot source payload in {jni_dir}")


def _is_proot_like_zip_name(name: str) -> bool:
    basename = PurePosixPath(name).name.lower()
    return basename.startswith("libproot") or basename.startswith("libtalloc")


def _validate_zip_layout(archive: zipfile.ZipFile, apk: Path) -> dict[str, zipfile.ZipInfo]:
    infos = archive.infolist()
    names = [info.filename for info in infos]
    duplicates = sorted(name for name, count in Counter(names).items() if count > 1)
    if duplicates:
        raise VerificationError(f"{apk}: duplicate ZIP entry {duplicates[0]!r}")

    by_name: dict[str, zipfile.ZipInfo] = {}
    for info in infos:
        name = info.filename
        file_type = stat.S_IFMT((info.external_attr >> 16) & 0xFFFF)
        if file_type in UNSAFE_ZIP_FILE_TYPES:
            raise VerificationError(
                f"{apk}: ZIP entry {name!r} has an unsafe nonregular file type"
            )
        if not name or "\0" in name or "\\" in name:
            raise VerificationError(f"{apk}: ambiguous ZIP path {name!r}")
        if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
            raise VerificationError(f"{apk}: absolute ZIP path {name!r}")
        raw_parts = name.split("/")
        if any(part == ".." for part in raw_parts):
            raise VerificationError(f"{apk}: traversing ZIP path {name!r}")
        if any(part == "." for part in raw_parts) or any(
            part == "" for part in raw_parts[:-1]
        ):
            raise VerificationError(f"{apk}: ambiguous ZIP path {name!r}")
        if raw_parts[-1] == "" and not info.is_dir():
            raise VerificationError(f"{apk}: ambiguous ZIP directory path {name!r}")
        by_name[name] = info
    return by_name


def _verify_zip_regular(info: zipfile.ZipInfo, apk: Path) -> None:
    mode = (info.external_attr >> 16) & 0xFFFF
    file_type = stat.S_IFMT(mode)
    if info.create_system != 3 or info.is_dir() or file_type != stat.S_IFREG:
        raise VerificationError(
            f"{apk}: required entry {info.filename!r} has no unambiguous regular-file mode"
        )


def verify_apk_payloads(
    apk: Path, *, mode: str, expected_abi: str | None = None
) -> list[str]:
    try:
        apk_mode = apk.lstat().st_mode
    except FileNotFoundError as error:
        raise VerificationError(f"APK not found: {apk}") from error
    if stat.S_ISLNK(apk_mode) or not stat.S_ISREG(apk_mode):
        raise VerificationError(f"APK is not a regular file: {apk}")
    if mode == "universal":
        if expected_abi is not None:
            raise VerificationError("universal APK mode does not accept --expected-abi")
        expected_abis = set(SUPPORTED_ABIS)
    elif mode == "split":
        if expected_abi not in SUPPORTED_ABIS:
            raise VerificationError("split APK mode requires a supported --expected-abi")
        expected_abis = {expected_abi}
    else:
        raise VerificationError(f"invalid APK mode: {mode}")

    with zipfile.ZipFile(apk) as archive:
        by_name = _validate_zip_layout(archive, apk)
        allowed_proot_entries = {
            f"lib/{abi}/{name}" for abi, name in _expected_payloads(expected_abis)
        }
        for name in by_name:
            if _is_proot_like_zip_name(name) and name not in allowed_proot_entries:
                raise VerificationError(f"{apk}: unexpected PRoot-like entry {name!r}")
        missing = sorted(allowed_proot_entries - set(by_name))
        if missing:
            raise VerificationError(f"{apk}: missing required entry {missing[0]!r}")
        for entry in sorted(allowed_proot_entries):
            info = by_name[entry]
            _verify_zip_regular(info, apk)
            _, abi, name = entry.split("/")
            data = archive.read(info)
            if len(data) < MIN_ELF_SIZE:
                raise VerificationError(
                    f"{apk}:{entry}: payload is too small ({len(data)} bytes)"
                )
            _verify_elf(data, abi, name, f"{apk}:{entry}")
    return sorted(expected_abis)


def _find_android_tool(name: str, android_dir: Path) -> Path:
    sdk_roots = [
        Path(value)
        for value in (os.environ.get("ANDROID_SDK_ROOT"), os.environ.get("ANDROID_HOME"))
        if value
    ]
    local_properties = android_dir / "local.properties"
    if local_properties.is_file():
        match = re.search(
            r"(?m)^sdk\.dir=(.+)$", local_properties.read_text(encoding="utf-8")
        )
        if match:
            sdk_roots.append(Path(match.group(1).replace(r"\:", ":")))
    candidates: list[Path] = []
    for sdk_root in sdk_roots:
        candidates.extend(
            candidate
            for candidate in (sdk_root / "build-tools").glob(f"*/{name}")
            if candidate.is_file() and os.access(candidate, os.X_OK)
        )
    if not candidates:
        raise VerificationError(f"Android SDK tool not found: {name}")

    def version_key(path: Path) -> tuple[int, ...]:
        return tuple(int(part) for part in re.findall(r"\d+", path.parent.name))

    return max(candidates, key=version_key)


def _verify_manifest(aapt2: Path, apk: Path) -> None:
    commands = [
        [str(aapt2), "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)],
        [str(aapt2), "dump", "xmltree", str(apk), "AndroidManifest.xml"],
    ]
    failures: list[str] = []
    for command in commands:
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        if result.returncode != 0:
            failures.append(result.stderr.strip() or f"exit {result.returncode}")
            continue
        line = next(
            (line for line in result.stdout.splitlines() if "extractNativeLibs" in line),
            None,
        )
        if line is None:
            raise VerificationError(f"{apk}: manifest is missing extractNativeLibs=true")
        if not re.search(r"(?:=true\b|=\(type 0x12\)0xffffffff\b)", line):
            raise VerificationError(f"{apk}: manifest does not set extractNativeLibs=true")
        return
    raise VerificationError(f"{apk}: aapt2 manifest inspection failed: {failures[-1]}")


def verify_apk(
    apk: Path, android_dir: Path, *, mode: str, expected_abi: str | None = None
) -> None:
    packaged_abis = verify_apk_payloads(apk, mode=mode, expected_abi=expected_abi)
    aapt2 = _find_android_tool("aapt2", android_dir)
    zipalign = _find_android_tool("zipalign", android_dir)
    _verify_manifest(aapt2, apk)
    result = subprocess.run(
        [str(zipalign), "-c", "-P", "16", "4", str(apk)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise VerificationError(f"{apk}: zipalign 16 KiB verification failed: {detail}")
    print(
        f"PASS: verified {mode} PRoot APK payload for {', '.join(packaged_abis)} in {apk}"
    )


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--jni-dir", type=Path)
    group.add_argument("--apk", type=Path)
    parser.add_argument(
        "--artifact-mode", choices=ARTIFACT_MODES, required=True
    )
    parser.add_argument("--expected-abi", choices=tuple(SUPPORTED_ABIS))
    parser.add_argument(
        "--android-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "flutter_app" / "android",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _argument_parser()
    args = parser.parse_args(argv)
    if args.jni_dir is not None and (
        args.artifact_mode != "source" or args.expected_abi
    ):
        parser.error(
            "--jni-dir requires --artifact-mode source and no --expected-abi"
        )
    if args.apk is not None and args.artifact_mode == "source":
        parser.error("--apk requires --artifact-mode universal or split")
    if args.artifact_mode == "split" and not args.expected_abi:
        parser.error("--artifact-mode split requires --expected-abi")
    if args.artifact_mode == "universal" and args.expected_abi:
        parser.error("--artifact-mode universal does not accept --expected-abi")
    try:
        if args.jni_dir is not None:
            verify_jni_dir(args.jni_dir)
        else:
            verify_apk(
                args.apk,
                args.android_dir,
                mode=args.artifact_mode,
                expected_abi=args.expected_abi,
            )
    except (OSError, VerificationError, zipfile.BadZipFile) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
