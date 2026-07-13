#!/usr/bin/env python3
"""Deterministic offline regression tests for verify-proot-packaging.py."""

from __future__ import annotations

import contextlib
import importlib.util
import os
from pathlib import Path
import stat
import struct
import subprocess
import tempfile
import unittest
import warnings
import zipfile


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent
VERIFIER_PATH = SCRIPT_DIR / "verify-proot-packaging.py"
SPEC = importlib.util.spec_from_file_location("verify_proot_packaging", VERIFIER_PATH)
assert SPEC is not None and SPEC.loader is not None
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


def _synthetic_elf(abi: str, name: str, *, loader_interpreter: bool = False) -> bytes:
    elf_class, machine = VERIFIER.SUPPORTED_ABIS[abi][name]
    is_loader = name.startswith("libprootloader")
    elf_type = VERIFIER.ET_EXEC if is_loader else VERIFIER.ET_DYN
    interpreter: str | None = None
    needed: list[str] = []
    soname: str | None = None
    if name == "libproot.so":
        interpreter = "/system/bin/linker64" if elf_class == 2 else "/system/bin/linker"
        needed = ["libtalloc.so.2", "libc.so"]
    elif name == "libtalloc.so":
        needed = ["libc.so"]
        soname = "libtalloc.so.2"
    if loader_interpreter and interpreter is None:
        interpreter = "/system/bin/linker64" if elf_class == 2 else "/system/bin/linker"

    size = 8192
    data = bytearray(size)
    data[:16] = b"\x7fELF" + bytes([elf_class, 1, 1]) + bytes(9)
    phoff = 64 if elf_class == 2 else 52
    ph_format = "<IIQQQQQQ" if elf_class == 2 else "<IIIIIIII"
    phentsize = struct.calcsize(ph_format)
    phnum = 1 + int(interpreter is not None) + int(bool(needed or soname))
    vaddr = 0x4000 if elf_class == 2 else 0x1000
    entry = vaddr + 0x100
    header_format = "<HHIQQQIHHHHHH" if elf_class == 2 else "<HHIIIIIHHHHHH"
    header = struct.pack(
        header_format,
        elf_type,
        machine,
        1,
        entry,
        phoff,
        0,
        0,
        64 if elf_class == 2 else 52,
        phentsize,
        phnum,
        0,
        0,
        0,
    )
    data[16 : 16 + len(header)] = header

    alignment = 16384 if elf_class == 2 else 4096
    load = (
        struct.pack(ph_format, 1, 5, 0, vaddr, 0, size, size, alignment)
        if elf_class == 2
        else struct.pack(ph_format, 1, 0, vaddr, 0, size, size, 5, alignment)
    )
    data[phoff : phoff + phentsize] = load
    ph_index = 1

    if interpreter is not None:
        interp_offset = 0x300
        interp_bytes = interpreter.encode() + b"\0"
        data[interp_offset : interp_offset + len(interp_bytes)] = interp_bytes
        interp = (
            struct.pack(
                ph_format, 3, 4, interp_offset, vaddr + interp_offset, 0,
                len(interp_bytes), len(interp_bytes), 1,
            )
            if elf_class == 2
            else struct.pack(
                ph_format, 3, interp_offset, vaddr + interp_offset, 0,
                len(interp_bytes), len(interp_bytes), 4, 1,
            )
        )
        offset = phoff + ph_index * phentsize
        data[offset : offset + phentsize] = interp
        ph_index += 1

    if needed or soname:
        string_offset = 0x500
        strings = bytearray(b"\0")
        string_indexes: dict[str, int] = {}
        for value in [*needed, *([soname] if soname else [])]:
            if value not in string_indexes:
                string_indexes[value] = len(strings)
                strings.extend(value.encode() + b"\0")
        data[string_offset : string_offset + len(strings)] = strings

        dynamic_format = "<QQ" if elf_class == 2 else "<II"
        dynamic_values = [(5, vaddr + string_offset), (10, len(strings))]
        dynamic_values.extend((1, string_indexes[value]) for value in needed)
        if soname is not None:
            dynamic_values.append((14, string_indexes[soname]))
        dynamic_values.append((0, 0))
        dynamic_bytes = b"".join(
            struct.pack(dynamic_format, tag, value) for tag, value in dynamic_values
        )
        dynamic_offset = 0x400
        data[dynamic_offset : dynamic_offset + len(dynamic_bytes)] = dynamic_bytes
        dynamic = (
            struct.pack(
                ph_format, 2, 6, dynamic_offset, vaddr + dynamic_offset, 0,
                len(dynamic_bytes), len(dynamic_bytes), 8,
            )
            if elf_class == 2
            else struct.pack(
                ph_format, 2, dynamic_offset, vaddr + dynamic_offset, 0,
                len(dynamic_bytes), len(dynamic_bytes), 6, 4,
            )
        )
        offset = phoff + ph_index * phentsize
        data[offset : offset + phentsize] = dynamic
    return bytes(data)


def _header_layout(data: bytes) -> tuple[str, list[int]]:
    header_format = "<HHIQQQIHHHHHH" if data[4] == 2 else "<HHIIIIIHHHHHH"
    return header_format, list(struct.unpack_from(header_format, data, 16))


def _mutate_header(data: bytes, field: str, value: int) -> bytes:
    indexes = {"type": 0, "machine": 1, "entry": 3, "phoff": 4, "phentsize": 8, "phnum": 9}
    result = bytearray(data)
    header_format, values = _header_layout(data)
    values[indexes[field]] = value
    struct.pack_into(header_format, result, 16, *values)
    return bytes(result)


def _ph_layout(data: bytes) -> tuple[str, int, int]:
    _, header = _header_layout(data)
    return ("<IIQQQQQQ" if data[4] == 2 else "<IIIIIIII", header[4], header[8])


def _mutate_ph(data: bytes, index: int, field: str, value: int) -> bytes:
    result = bytearray(data)
    ph_format, phoff, phentsize = _ph_layout(data)
    values = list(struct.unpack_from(ph_format, data, phoff + index * phentsize))
    indexes64 = {"type": 0, "flags": 1, "offset": 2, "vaddr": 3, "filesz": 5, "memsz": 6, "align": 7}
    indexes32 = {"type": 0, "offset": 1, "vaddr": 2, "filesz": 4, "memsz": 5, "flags": 6, "align": 7}
    values[(indexes64 if data[4] == 2 else indexes32)[field]] = value
    struct.pack_into(ph_format, result, phoff + index * phentsize, *values)
    return bytes(result)


def _mutate_dynamic_tag(data: bytes, tag_to_change: int, new_value: int) -> bytes:
    result = bytearray(data)
    ph_format, phoff, phentsize = _ph_layout(data)
    dynamic_format = "<QQ" if data[4] == 2 else "<II"
    for ph_index in range(_header_layout(data)[1][9]):
        values = struct.unpack_from(ph_format, data, phoff + ph_index * phentsize)
        if values[0] != VERIFIER.PT_DYNAMIC:
            continue
        dynamic_offset = values[2] if data[4] == 2 else values[1]
        dynamic_size = values[5] if data[4] == 2 else values[4]
        for offset in range(dynamic_offset, dynamic_offset + dynamic_size, struct.calcsize(dynamic_format)):
            tag, _ = struct.unpack_from(dynamic_format, data, offset)
            if tag == tag_to_change:
                struct.pack_into(dynamic_format, result, offset, tag, new_value)
                return bytes(result)
    raise AssertionError(f"dynamic tag {tag_to_change} not found")


def _write_valid_payloads(root: Path) -> None:
    for abi, libraries in VERIFIER.SUPPORTED_ABIS.items():
        for name in libraries:
            path = root / abi / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(_synthetic_elf(abi, name))
            path.chmod(0o755)


def _write_apk(apk: Path, abis: set[str], *, omit: str | None = None) -> None:
    with zipfile.ZipFile(apk, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("AndroidManifest.xml", b"binary manifest placeholder")
        archive.writestr("assets/ordinary.txt", b"ordinary")
        for abi in sorted(abis):
            for name in VERIFIER.SUPPORTED_ABIS[abi]:
                entry = f"lib/{abi}/{name}"
                if entry != omit:
                    info = zipfile.ZipInfo(entry)
                    info.create_system = 3
                    info.external_attr = (stat.S_IFREG | 0o644) << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, _synthetic_elf(abi, name))


def _append_entry(
    apk: Path,
    name: str,
    data: bytes = b"x",
    *,
    mode: int | None = None,
    create_system: int = 3,
) -> None:
    with zipfile.ZipFile(apk, "a") as archive:
        if mode is None and create_system == 3:
            archive.writestr(name, data)
        else:
            info = zipfile.ZipInfo(name)
            info.create_system = create_system
            info.external_attr = 0 if mode is None else mode << 16
            archive.writestr(info, data)


def _fake_sdk(root: Path, *, manifest: str = "true", aapt_exit: int = 0, zipalign_exit: int = 0, include_zipalign: bool = True) -> Path:
    build_tools = root / "build-tools" / "35.0.0"
    build_tools.mkdir(parents=True)
    aapt2 = build_tools / "aapt2"
    if aapt_exit:
        aapt2.write_text(f"#!/bin/sh\necho aapt-failed >&2\nexit {aapt_exit}\n", encoding="utf-8")
    else:
        if manifest == "true":
            output = "A: android:extractNativeLibs(0x010104ea)=true"
        elif manifest == "false":
            output = "A: android:extractNativeLibs(0x010104ea)=false"
        else:
            output = "A: android:label=ClawChat"
        aapt2.write_text(f"#!/bin/sh\necho '{output}'\n", encoding="utf-8")
    aapt2.chmod(0o755)
    if include_zipalign:
        zipalign = build_tools / "zipalign"
        zipalign.write_text(
            f"#!/bin/sh\necho zipalign-result >&2\nexit {zipalign_exit}\n", encoding="utf-8"
        )
        zipalign.chmod(0o755)
    return root


@contextlib.contextmanager
def _sdk_environment(sdk: Path | None):
    old_root = os.environ.pop("ANDROID_SDK_ROOT", None)
    old_home = os.environ.pop("ANDROID_HOME", None)
    if sdk is not None:
        os.environ["ANDROID_SDK_ROOT"] = str(sdk)
    try:
        yield
    finally:
        os.environ.pop("ANDROID_SDK_ROOT", None)
        if old_root is not None:
            os.environ["ANDROID_SDK_ROOT"] = old_root
        if old_home is not None:
            os.environ["ANDROID_HOME"] = old_home


class VerifierTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="proot-verifier-test-")
        self.root = Path(self.temp_dir.name)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def assertElfRejected(self, data: bytes, abi: str = "arm64-v8a", name: str = "libprootloader.so", regex: str = ".") -> None:
        with self.assertRaisesRegex(VERIFIER.VerificationError, regex):
            VERIFIER._verify_elf(data, abi, name, "fixture")


class ElfStructureTests(VerifierTestCase):
    def test_valid_elf_is_accepted(self) -> None:
        VERIFIER._verify_elf(_synthetic_elf("arm64-v8a", "libprootloader.so"), "arm64-v8a", "libprootloader.so", "fixture")

    def test_phnum_zero_is_rejected(self) -> None:
        self.assertElfRejected(_mutate_header(_synthetic_elf("arm64-v8a", "libprootloader.so"), "phnum", 0), regex="no program headers")

    def test_52_byte_et_exec_without_program_headers_is_rejected(self) -> None:
        data = bytearray(52)
        data[:16] = b"\x7fELF" + bytes([1, 1, 1]) + bytes(9)
        struct.pack_into(
            "<HHIIIIIHHHHHH",
            data,
            16,
            VERIFIER.ET_EXEC,
            40,
            1,
            0x1100,
            52,
            0,
            0,
            52,
            32,
            0,
            0,
            0,
            0,
        )
        self.assertElfRejected(
            bytes(data),
            abi="armeabi-v7a",
            name="libprootloader.so",
            regex="no program headers",
        )

    def test_no_pt_load_is_rejected(self) -> None:
        self.assertElfRejected(_mutate_ph(_synthetic_elf("arm64-v8a", "libprootloader.so"), 0, "type", 4), regex="no PT_LOAD")

    def test_zero_alignment_is_rejected(self) -> None:
        self.assertElfRejected(_mutate_ph(_synthetic_elf("arm64-v8a", "libprootloader.so"), 0, "align", 0), regex="nonzero power")

    def test_non_power_of_two_alignment_is_rejected(self) -> None:
        self.assertElfRejected(_mutate_ph(_synthetic_elf("arm64-v8a", "libprootloader.so"), 0, "align", 24576), regex="nonzero power")

    def test_incongruent_offset_and_vaddr_are_rejected(self) -> None:
        self.assertElfRejected(_mutate_ph(_synthetic_elf("arm64-v8a", "libprootloader.so"), 0, "vaddr", 0x4001), regex="incongruent")

    def test_filesz_greater_than_memsz_is_rejected(self) -> None:
        data = _mutate_ph(_synthetic_elf("arm64-v8a", "libprootloader.so"), 0, "memsz", 1024)
        self.assertElfRejected(data, regex="p_filesz greater")

    def test_program_segment_out_of_file_is_rejected(self) -> None:
        data = _mutate_ph(_synthetic_elf("arm64-v8a", "libprootloader.so"), 0, "offset", 16384)
        self.assertElfRejected(data, regex="range exceeds")

    def test_virtual_address_overflow_is_rejected(self) -> None:
        data = _mutate_ph(
            _synthetic_elf("arm64-v8a", "libprootloader.so"),
            0,
            "vaddr",
            (1 << 64) - 4096,
        )
        self.assertElfRejected(data, regex="virtual-address range overflows")

    def test_64_bit_4k_alignment_is_rejected(self) -> None:
        data = _mutate_ph(_synthetic_elf("arm64-v8a", "libprootloader.so"), 0, "align", 4096)
        self.assertElfRejected(data, regex="16 KiB")

    def test_static_loader_zero_entry_is_rejected(self) -> None:
        self.assertElfRejected(_mutate_header(_synthetic_elf("arm64-v8a", "libprootloader.so"), "entry", 0), regex="zero entry")

    def test_static_loader_entry_outside_loads_is_rejected(self) -> None:
        self.assertElfRejected(_mutate_header(_synthetic_elf("arm64-v8a", "libprootloader.so"), "entry", 0x900000), regex="outside executable")

    def test_static_loader_entry_must_be_file_backed(self) -> None:
        data = _mutate_ph(
            _synthetic_elf("arm64-v8a", "libprootloader.so"),
            0,
            "filesz",
            0x80,
        )
        self.assertElfRejected(data, regex="outside executable")

    def test_static_loader_without_executable_segment_is_rejected(self) -> None:
        self.assertElfRejected(_mutate_ph(_synthetic_elf("arm64-v8a", "libprootloader.so"), 0, "flags", 4), regex="outside executable")

    def test_wrong_class_is_rejected(self) -> None:
        self.assertElfRejected(_synthetic_elf("x86_64", "libprootloader32.so"), regex="wrong ELF ABI")

    def test_wrong_machine_is_rejected(self) -> None:
        data = _mutate_header(_synthetic_elf("arm64-v8a", "libprootloader.so"), "machine", 62)
        self.assertElfRejected(data, regex="wrong ELF ABI")

    def test_wrong_type_is_rejected(self) -> None:
        data = _mutate_header(_synthetic_elf("arm64-v8a", "libprootloader.so"), "type", VERIFIER.ET_DYN)
        self.assertElfRejected(data, regex="not static ET_EXEC")

    def test_truncated_elf_is_rejected(self) -> None:
        self.assertElfRejected(_synthetic_elf("arm64-v8a", "libprootloader.so")[:40], regex="truncated")

    def test_static_loader_pt_interp_is_rejected(self) -> None:
        self.assertElfRejected(_synthetic_elf("arm64-v8a", "libprootloader.so", loader_interpreter=True), regex="not static ET_EXEC")

    def test_libtalloc_pt_interp_is_rejected(self) -> None:
        data = _synthetic_elf("arm64-v8a", "libtalloc.so", loader_interpreter=True)
        self.assertElfRejected(data, name="libtalloc.so", regex="must not contain PT_INTERP")

    def test_dynamic_string_address_outside_load_is_rejected(self) -> None:
        data = _mutate_dynamic_tag(_synthetic_elf("arm64-v8a", "libproot.so"), VERIFIER.DT_STRTAB, 0x900000)
        self.assertElfRejected(data, name="libproot.so", regex="not file-backed")

    def test_dynamic_segment_mapping_mismatch_is_rejected(self) -> None:
        data = _mutate_ph(
            _synthetic_elf("arm64-v8a", "libproot.so"),
            2,
            "vaddr",
            0x4501,
        )
        self.assertElfRejected(data, name="libproot.so", regex="PT_DYNAMIC")

    def test_dynamic_string_size_outside_load_is_rejected(self) -> None:
        data = _mutate_dynamic_tag(_synthetic_elf("arm64-v8a", "libproot.so"), VERIFIER.DT_STRSZ, 0x900000)
        self.assertElfRejected(data, name="libproot.so", regex="not file-backed")

    def test_needed_mutation_is_rejected(self) -> None:
        data = _synthetic_elf("arm64-v8a", "libproot.so").replace(b"libc.so\0", b"libx.so\0")
        self.assertElfRejected(data, name="libproot.so", regex="unexpected dependencies")

    def test_soname_mutation_is_rejected(self) -> None:
        data = _synthetic_elf("arm64-v8a", "libtalloc.so").replace(b"libtalloc.so.2", b"libtalloc.so.3")
        self.assertElfRejected(data, name="libtalloc.so", regex="invalid libtalloc SONAME")

    def test_e009f15_magic_and_size_only_behavior_is_rejected(self) -> None:
        data = b"\x7fELF" + bytes(VERIFIER.MIN_ELF_SIZE)
        self.assertElfRejected(data, regex="unsupported ELF")


class SourceLayoutTests(VerifierTestCase):
    def test_valid_source_exact_matrix_passes(self) -> None:
        payloads = self.root / "jniLibs"
        _write_valid_payloads(payloads)
        VERIFIER.verify_jni_dir(payloads)

    def test_missing_all_source_payloads_fail(self) -> None:
        with self.assertRaisesRegex(VERIFIER.VerificationError, "missing jniLibs"):
            VERIFIER.verify_jni_dir(self.root / "jniLibs")

    def test_missing_one_source_payload_fails(self) -> None:
        payloads = self.root / "jniLibs"
        _write_valid_payloads(payloads)
        (payloads / "arm64-v8a" / "libtalloc.so").unlink()
        with self.assertRaisesRegex(VERIFIER.VerificationError, "files must be exactly"):
            VERIFIER.verify_jni_dir(payloads)

    def test_missing_source_abi_fails(self) -> None:
        payloads = self.root / "jniLibs"
        _write_valid_payloads(payloads)
        missing_abi = payloads / "x86_64"
        for child in missing_abi.iterdir():
            child.unlink()
        missing_abi.rmdir()
        with self.assertRaisesRegex(
            VERIFIER.VerificationError, "ABI directories must be exactly"
        ):
            VERIFIER.verify_jni_dir(payloads)

    def test_source_symlink_is_rejected(self) -> None:
        payloads = self.root / "jniLibs"
        _write_valid_payloads(payloads)
        target = payloads / "arm64-v8a" / "libproot.so"
        target.unlink()
        target.symlink_to(payloads / "x86_64" / "libproot.so")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "symlink"):
            VERIFIER.verify_jni_dir(payloads)

    def test_source_nonregular_file_is_rejected(self) -> None:
        payloads = self.root / "jniLibs"
        _write_valid_payloads(payloads)
        target = payloads / "x86_64" / "libtalloc.so"
        target.unlink()
        target.mkdir()
        with self.assertRaisesRegex(VERIFIER.VerificationError, "regular file"):
            VERIFIER.verify_jni_dir(payloads)

    def test_source_non_executable_file_is_rejected(self) -> None:
        payloads = self.root / "jniLibs"
        _write_valid_payloads(payloads)
        (payloads / "armeabi-v7a" / "libproot.so").chmod(0o644)
        with self.assertRaisesRegex(VERIFIER.VerificationError, "not executable"):
            VERIFIER.verify_jni_dir(payloads)

    def test_source_unsupported_abi_directory_is_rejected(self) -> None:
        payloads = self.root / "jniLibs"
        _write_valid_payloads(payloads)
        unsupported = payloads / "riscv64"
        unsupported.mkdir()
        (unsupported / "libproot.so").write_bytes(b"hostile")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "ABI directories must be exactly"):
            VERIFIER.verify_jni_dir(payloads)

    def test_source_abi_directory_symlink_is_rejected(self) -> None:
        payloads = self.root / "jniLibs"
        _write_valid_payloads(payloads)
        arm = payloads / "armeabi-v7a"
        for child in arm.iterdir():
            child.unlink()
        arm.rmdir()
        arm.symlink_to(payloads / "arm64-v8a", target_is_directory=True)
        with self.assertRaisesRegex(VERIFIER.VerificationError, "not a real directory"):
            VERIFIER.verify_jni_dir(payloads)

    def test_source_extra_proot_name_is_rejected(self) -> None:
        payloads = self.root / "jniLibs"
        _write_valid_payloads(payloads)
        (payloads / "arm64-v8a" / "libproot-extra.so").write_bytes(b"extra")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "files must be exactly"):
            VERIFIER.verify_jni_dir(payloads)


class ApkIdentityAndLayoutTests(VerifierTestCase):
    def test_valid_universal_apk_passes(self) -> None:
        apk = self.root / "universal.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        self.assertEqual(VERIFIER.verify_apk_payloads(apk, mode="universal"), sorted(VERIFIER.SUPPORTED_ABIS))

    def test_every_valid_split_passes(self) -> None:
        for abi in VERIFIER.SUPPORTED_ABIS:
            with self.subTest(abi=abi):
                apk = self.root / f"{abi}.apk"
                _write_apk(apk, {abi})
                self.assertEqual(VERIFIER.verify_apk_payloads(apk, mode="split", expected_abi=abi), [abi])

    def test_universal_missing_one_abi_is_rejected(self) -> None:
        apk = self.root / "missing-x86.apk"
        _write_apk(apk, {"arm64-v8a", "armeabi-v7a"})
        with self.assertRaisesRegex(VERIFIER.VerificationError, "missing required entry"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_mislabeled_split_is_rejected(self) -> None:
        apk = self.root / "arm64-label.apk"
        _write_apk(apk, {"x86_64"})
        with self.assertRaisesRegex(VERIFIER.VerificationError, "unexpected PRoot-like"):
            VERIFIER.verify_apk_payloads(apk, mode="split", expected_abi="arm64-v8a")

    def test_split_with_other_supported_abi_is_rejected(self) -> None:
        apk = self.root / "mixed.apk"
        _write_apk(apk, {"arm64-v8a", "x86_64"})
        with self.assertRaisesRegex(VERIFIER.VerificationError, "unexpected PRoot-like"):
            VERIFIER.verify_apk_payloads(apk, mode="split", expected_abi="arm64-v8a")

    def test_unsupported_riscv64_proot_is_rejected(self) -> None:
        apk = self.root / "riscv.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        _append_entry(apk, "lib/riscv64/libproot.so", _synthetic_elf("arm64-v8a", "libproot.so"))
        with self.assertRaisesRegex(VERIFIER.VerificationError, "unexpected PRoot-like"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_extra_proot_name_is_rejected(self) -> None:
        apk = self.root / "extra.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        _append_entry(apk, "lib/arm64-v8a/libproot-extra.so")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "unexpected PRoot-like"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_unexpected_loader32_is_rejected(self) -> None:
        apk = self.root / "loader32.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        _append_entry(apk, "lib/armeabi-v7a/libprootloader32.so", _synthetic_elf("arm64-v8a", "libprootloader32.so"))
        with self.assertRaisesRegex(VERIFIER.VerificationError, "unexpected PRoot-like"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_absolute_zip_path_is_rejected(self) -> None:
        apk = self.root / "absolute.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        _append_entry(apk, "/assets/evil")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "absolute ZIP"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_traversing_zip_path_is_rejected(self) -> None:
        apk = self.root / "traversal.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        _append_entry(apk, "assets/../evil")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "traversing ZIP"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_backslash_zip_path_is_rejected(self) -> None:
        apk = self.root / "backslash.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        _append_entry(apk, r"assets\evil")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "ambiguous ZIP"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_global_duplicate_zip_name_is_rejected(self) -> None:
        apk = self.root / "duplicate.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            _append_entry(apk, "assets/ordinary.txt", b"duplicate")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "duplicate ZIP"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_required_zip_symlink_is_rejected(self) -> None:
        apk = self.root / "symlink.apk"
        _write_apk(apk, {"arm64-v8a"}, omit="lib/arm64-v8a/libproot.so")
        _append_entry(
            apk,
            "lib/arm64-v8a/libproot.so",
            b"libprootloader.so",
            mode=stat.S_IFLNK | 0o777,
        )
        with self.assertRaisesRegex(VERIFIER.VerificationError, "unsafe nonregular"):
            VERIFIER.verify_apk_payloads(apk, mode="split", expected_abi="arm64-v8a")

    def test_required_zip_nonregular_mode_is_rejected(self) -> None:
        apk = self.root / "fifo.apk"
        _write_apk(apk, {"arm64-v8a"}, omit="lib/arm64-v8a/libproot.so")
        _append_entry(
            apk,
            "lib/arm64-v8a/libproot.so",
            _synthetic_elf("arm64-v8a", "libproot.so"),
            mode=stat.S_IFIFO | 0o600,
        )
        with self.assertRaisesRegex(VERIFIER.VerificationError, "unsafe nonregular"):
            VERIFIER.verify_apk_payloads(apk, mode="split", expected_abi="arm64-v8a")

    def test_required_zip_device_mode_is_rejected(self) -> None:
        apk = self.root / "device.apk"
        _write_apk(apk, {"arm64-v8a"}, omit="lib/arm64-v8a/libproot.so")
        _append_entry(
            apk,
            "lib/arm64-v8a/libproot.so",
            _synthetic_elf("arm64-v8a", "libproot.so"),
            mode=stat.S_IFCHR | 0o600,
        )
        with self.assertRaisesRegex(VERIFIER.VerificationError, "unsafe nonregular"):
            VERIFIER.verify_apk_payloads(apk, mode="split", expected_abi="arm64-v8a")

    def test_required_zip_ambiguous_mode_is_rejected(self) -> None:
        apk = self.root / "ambiguous-mode.apk"
        _write_apk(apk, {"arm64-v8a"}, omit="lib/arm64-v8a/libproot.so")
        _append_entry(
            apk,
            "lib/arm64-v8a/libproot.so",
            _synthetic_elf("arm64-v8a", "libproot.so"),
            mode=0o644,
        )
        with self.assertRaisesRegex(VERIFIER.VerificationError, "regular-file mode"):
            VERIFIER.verify_apk_payloads(apk, mode="split", expected_abi="arm64-v8a")

    def test_dot_component_zip_path_is_rejected(self) -> None:
        apk = self.root / "dot.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        _append_entry(apk, "assets/./evil")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "ambiguous ZIP"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_double_slash_zip_path_is_rejected(self) -> None:
        apk = self.root / "double-slash.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        _append_entry(apk, "assets//evil")
        with self.assertRaisesRegex(VERIFIER.VerificationError, "ambiguous ZIP"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_unrelated_explicit_zip_symlink_is_rejected(self) -> None:
        apk = self.root / "unrelated-symlink.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        _append_entry(
            apk,
            "assets/AssetManifest.bin",
            b"assets/real-manifest",
            mode=stat.S_IFLNK | 0o777,
        )
        with self.assertRaisesRegex(VERIFIER.VerificationError, "unsafe nonregular"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_unrelated_explicit_zip_fifo_is_rejected(self) -> None:
        apk = self.root / "unrelated-fifo.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        _append_entry(
            apk,
            "assets/runtime-pipe",
            b"pipe",
            mode=stat.S_IFIFO | 0o600,
        )
        with self.assertRaisesRegex(VERIFIER.VerificationError, "unsafe nonregular"):
            VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_unrelated_explicit_zip_device_types_are_rejected(self) -> None:
        device_types = {
            "socket": stat.S_IFSOCK,
            "block": stat.S_IFBLK,
            "character": stat.S_IFCHR,
        }
        for label, file_type in device_types.items():
            with self.subTest(file_type=label):
                apk = self.root / f"unrelated-{label}.apk"
                _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
                _append_entry(
                    apk,
                    f"assets/{label}-device",
                    b"device",
                    mode=file_type | 0o600,
                )
                with self.assertRaisesRegex(
                    VERIFIER.VerificationError, "unsafe nonregular"
                ):
                    VERIFIER.verify_apk_payloads(apk, mode="universal")

    def test_legitimate_zip_directory_and_unspecified_mode_are_allowed(self) -> None:
        apk = self.root / "compatible-metadata.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        _append_entry(
            apk,
            "assets/empty-directory/",
            b"",
            mode=stat.S_IFDIR | 0o755,
        )
        _append_entry(
            apk,
            "assets/platform-unspecified.bin",
            b"ordinary",
            mode=None,
            create_system=0,
        )
        self.assertEqual(
            VERIFIER.verify_apk_payloads(apk, mode="universal"),
            sorted(VERIFIER.SUPPORTED_ABIS),
        )


class AndroidToolAndManifestTests(VerifierTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.apk = self.root / "valid.apk"
        _write_apk(self.apk, set(VERIFIER.SUPPORTED_ABIS))
        self.android_dir = self.root / "android"
        self.android_dir.mkdir()

    def test_manifest_extract_native_libs_true_passes(self) -> None:
        sdk = _fake_sdk(self.root / "sdk")
        with _sdk_environment(sdk):
            VERIFIER.verify_apk(self.apk, self.android_dir, mode="universal")

    def test_manifest_extract_native_libs_false_fails(self) -> None:
        sdk = _fake_sdk(self.root / "sdk", manifest="false")
        with _sdk_environment(sdk), self.assertRaisesRegex(VERIFIER.VerificationError, "does not set"):
            VERIFIER.verify_apk(self.apk, self.android_dir, mode="universal")

    def test_manifest_extract_native_libs_missing_fails(self) -> None:
        sdk = _fake_sdk(self.root / "sdk", manifest="missing")
        with _sdk_environment(sdk), self.assertRaisesRegex(VERIFIER.VerificationError, "missing"):
            VERIFIER.verify_apk(self.apk, self.android_dir, mode="universal")

    def test_missing_aapt2_fails(self) -> None:
        sdk = self.root / "empty-sdk"
        sdk.mkdir()
        with _sdk_environment(sdk), self.assertRaisesRegex(VERIFIER.VerificationError, "aapt2"):
            VERIFIER.verify_apk(self.apk, self.android_dir, mode="universal")

    def test_missing_zipalign_fails(self) -> None:
        sdk = _fake_sdk(self.root / "sdk", include_zipalign=False)
        with _sdk_environment(sdk), self.assertRaisesRegex(VERIFIER.VerificationError, "zipalign"):
            VERIFIER.verify_apk(self.apk, self.android_dir, mode="universal")

    def test_aapt2_failure_fails_closed(self) -> None:
        sdk = _fake_sdk(self.root / "sdk", aapt_exit=7)
        with _sdk_environment(sdk), self.assertRaisesRegex(VERIFIER.VerificationError, "inspection failed"):
            VERIFIER.verify_apk(self.apk, self.android_dir, mode="universal")

    def test_zipalign_failure_fails_closed(self) -> None:
        sdk = _fake_sdk(self.root / "sdk", zipalign_exit=9)
        with _sdk_environment(sdk), self.assertRaisesRegex(VERIFIER.VerificationError, "16 KiB verification failed"):
            VERIFIER.verify_apk(self.apk, self.android_dir, mode="universal")


class CliAndWorkflowTests(VerifierTestCase):
    def _run_cli(self, *args: str, sdk: Path | None = None) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.pop("ANDROID_HOME", None)
        env.pop("ANDROID_SDK_ROOT", None)
        if sdk is not None:
            env["ANDROID_SDK_ROOT"] = str(sdk)
        return subprocess.run(
            ["python3", str(VERIFIER_PATH), *args],
            text=True,
            capture_output=True,
            check=False,
            env=env,
        )

    def test_cli_source_mode_exit_zero(self) -> None:
        payloads = self.root / "jniLibs"
        _write_valid_payloads(payloads)
        result = self._run_cli("--jni-dir", str(payloads), "--artifact-mode", "source")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cli_universal_mode_exit_zero(self) -> None:
        apk = self.root / "universal.apk"
        _write_apk(apk, set(VERIFIER.SUPPORTED_ABIS))
        sdk = _fake_sdk(self.root / "sdk")
        result = self._run_cli("--apk", str(apk), "--artifact-mode", "universal", "--android-dir", str(self.root / "android"), sdk=sdk)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cli_split_mode_exit_zero(self) -> None:
        apk = self.root / "arm64.apk"
        _write_apk(apk, {"arm64-v8a"})
        sdk = _fake_sdk(self.root / "sdk")
        result = self._run_cli(
            "--apk",
            str(apk),
            "--artifact-mode",
            "split",
            "--expected-abi",
            "arm64-v8a",
            "--android-dir",
            str(self.root / "android"),
            sdk=sdk,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cli_split_requires_expected_abi_exit_two(self) -> None:
        result = self._run_cli("--apk", "missing.apk", "--artifact-mode", "split")
        self.assertEqual(result.returncode, 2)

    def test_cli_source_rejects_split_mode_exit_two(self) -> None:
        result = self._run_cli("--jni-dir", "jni", "--artifact-mode", "split", "--expected-abi", "arm64-v8a")
        self.assertEqual(result.returncode, 2)

    def test_cli_verification_failure_exit_one(self) -> None:
        result = self._run_cli("--apk", "missing.apk", "--artifact-mode", "universal")
        self.assertEqual(result.returncode, 1)

    def test_workflow_has_only_explicit_verified_apk_publication(self) -> None:
        workflow = (PROJECT_DIR / ".github/workflows/flutter-build.yml").read_text(encoding="utf-8")
        lowered = workflow.lower()
        self.assertNotIn("appbundle", lowered)
        self.assertNotIn(".aab", lowered)
        self.assertNotIn("artifacts/*\n", workflow)
        self.assertIn("--artifact-mode universal", workflow)
        for abi in VERIFIER.SUPPORTED_ABIS:
            self.assertIn(f"--expected-abi {abi}", workflow)
        self.assertGreaterEqual(workflow.count("--artifact-mode split"), 3)

    def test_gradle_and_build_script_use_explicit_modes(self) -> None:
        gradle = (PROJECT_DIR / "flutter_app/android/app/build.gradle").read_text(encoding="utf-8")
        build_script = (SCRIPT_DIR / "build-apk.sh").read_text(encoding="utf-8")
        self.assertIn('"--artifact-mode",', gradle)
        self.assertIn("--artifact-mode source", build_script)
        self.assertIn("--artifact-mode universal", build_script)

    def test_canonical_build_script_fetches_pins_unconditionally_in_order(self) -> None:
        build_script = (SCRIPT_DIR / "build-apk.sh").read_text(encoding="utf-8")
        markers = (
            'python3 "$SCRIPT_DIR/test_verify_proot_packaging.py"',
            'bash "$SCRIPT_DIR/fetch-proot-binaries.sh"',
            "--artifact-mode source",
            "flutter build apk --release",
            "--artifact-mode universal",
        )
        positions = [build_script.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(build_script.count(markers[1]), 1)
        self.assertNotIn("if ! python3", build_script)
        self.assertIn("set -euo pipefail", build_script)

    def test_canonical_build_script_stops_on_test_or_fetch_failure(self) -> None:
        source = (SCRIPT_DIR / "build-apk.sh").read_text(encoding="utf-8")

        for label, test_exit, fetch_exit, expected_log in (
            ("test-failure", 7, 0, ["tests"]),
            ("fetch-failure", 0, 9, ["tests", "fetch"]),
        ):
            with self.subTest(failure=label):
                root = self.root / label
                scripts = root / "scripts"
                flutter_app = root / "flutter_app"
                fake_bin = root / "bin"
                scripts.mkdir(parents=True)
                flutter_app.mkdir()
                fake_bin.mkdir()
                log = root / "commands.log"

                build = scripts / "build-apk.sh"
                build.write_text(source, encoding="utf-8")
                build.chmod(0o755)
                (scripts / "test_verify_proot_packaging.py").write_text(
                    "import os\n"
                    "with open(os.environ['HARNESS_LOG'], 'a', encoding='utf-8') as stream:\n"
                    "    stream.write('tests\\n')\n"
                    f"raise SystemExit({test_exit})\n",
                    encoding="utf-8",
                )
                fetch = scripts / "fetch-proot-binaries.sh"
                fetch.write_text(
                    "#!/bin/bash\n"
                    "echo fetch >> \"$HARNESS_LOG\"\n"
                    f"exit {fetch_exit}\n",
                    encoding="utf-8",
                )
                fetch.chmod(0o755)
                fake_flutter = fake_bin / "flutter"
                fake_flutter.write_text(
                    "#!/bin/bash\n"
                    "echo flutter >> \"$HARNESS_LOG\"\n"
                    "exit 99\n",
                    encoding="utf-8",
                )
                fake_flutter.chmod(0o755)

                env = os.environ.copy()
                env["HARNESS_LOG"] = str(log)
                env["PATH"] = f"{fake_bin}{os.pathsep}{env['PATH']}"
                result = subprocess.run(
                    ["bash", str(build)],
                    text=True,
                    capture_output=True,
                    check=False,
                    env=env,
                )
                expected_exit = test_exit or fetch_exit
                self.assertEqual(result.returncode, expected_exit, result.stdout)
                self.assertEqual(log.read_text(encoding="utf-8").splitlines(), expected_log)

    def test_fetch_uses_pinned_hashes_and_staging(self) -> None:
        fetch = (SCRIPT_DIR / "fetch-proot-binaries.sh").read_text(encoding="utf-8")
        self.assertIn('PINNED_RELEASE_TAG="v2.0.0"', fetch)
        self.assertEqual(fetch.count('OpenClaw-v2.0.0-'), 3)
        self.assertGreaterEqual(len(__import__("re").findall(r'"[0-9a-f]{64}"', fetch)), 3)
        self.assertIn("STAGE_DIR", fetch)
        self.assertIn("--artifact-mode source", fetch)


if __name__ == "__main__":
    unittest.main(verbosity=2)
