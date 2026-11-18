"""Checks for package rejection paths; native smoke tests run in the packager."""

import io
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import package_c_api as package


class PackageChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_cache_with_blank_lines_and_comments(self):
        cache = self.root / "CMakeCache.txt"
        cache.write_text(
            "# Generated cache\n\n//Build type\nCMAKE_BUILD_TYPE:STRING=Release\n"
            "\n//Extensions\nBUILD_EXTENSIONS:STRING=\n"
            "NEUG_LITE:BOOL=ON\n"
        )
        self.assertEqual(
            package.read_cache(cache),
            {"CMAKE_BUILD_TYPE": "Release", "BUILD_EXTENSIONS": "", "NEUG_LITE": "ON"},
        )

    def test_archive_checksum_is_checked_before_extraction(self):
        archive = self.root / "package.tar.gz"
        archive.write_bytes(b"changed archive")
        (self.root / "package.tar.gz.sha256").write_text("0" * 64)
        work = self.root / "work"
        with patch.object(package, "host_arch", return_value="arm64"):
            with self.assertRaisesRegex(RuntimeError, "SHA256 mismatch"):
                package.verify(archive, work)
        self.assertFalse(work.exists())

    def test_archive_rejects_traversal_links_and_multiple_roots(self):
        for names, link in (
            (["../escape"], False),
            (["/absolute"], False),
            (["package/link"], True),
            (["one/file", "two/file"], False),
            (["package/file", "package/file"], False),
        ):
            with self.subTest(names=names, link=link):
                archive = self.root / "unsafe.tar.gz"
                destination = self.root / "extracted"
                with tarfile.open(archive, "w:gz") as tar:
                    for name in names:
                        info = tarfile.TarInfo(name)
                        if link:
                            info.type = tarfile.SYMTYPE
                            info.linkname = "../../escape"
                        tar.addfile(info)
                with self.assertRaises(RuntimeError):
                    package.extract_package(archive, destination)
                self.assertFalse(destination.exists())

    def test_archive_extracts_regular_files(self):
        archive = self.root / "safe.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            info = tarfile.TarInfo("package/include/neug.h")
            info.size = 6
            tar.addfile(info, io.BytesIO(b"header"))
        extracted = package.extract_package(archive, self.root / "unpacked")
        self.assertEqual((extracted / "include/neug.h").read_bytes(), b"header")

    def test_library_dependency_architecture_and_export_guards(self):
        header = self.root / "neug.h"
        header.write_text(
            "#include <stddef.h>\n#include <stdint.h>\n"
            "const char* neug_version(void);\n"
        )
        for dependency, arch, paths, symbols, message in (
            ("/usr/lib/libSystem.B.dylib", "arm64", "", "_neug_version", None),
            ("@rpath/libprotobuf.dylib", "arm64", "", "_neug_version", "Non-system"),
            (
                "/opt/homebrew/lib/libz.dylib",
                "arm64",
                "",
                "_neug_version",
                "Non-system",
            ),
            (
                "/usr/lib/libSystem.B.dylib",
                "x86_64",
                "",
                "_neug_version",
                "architecture",
            ),
            ("/usr/lib/libSystem.B.dylib", "arm64", "", "_neug_missing", "C exports"),
            (
                "/usr/lib/libSystem.B.dylib",
                "arm64",
                "cmd LC_RPATH\ncmdsize 32\npath /opt/neug/lib (offset 12)",
                "_neug_version",
                "rpaths",
            ),
        ):
            with self.subTest(dependency=dependency, arch=arch, message=message):

                def output(args):
                    if args[0] == "lipo":
                        return arch
                    if args[:2] == ["otool", "-L"]:
                        return (
                            "libneug.dylib:\n"
                            " @rpath/libneug.dylib (compatibility version 0.0.0)\n"
                            f" {dependency} (compatibility version 0.0.0)"
                        )
                    if args[:2] == ["otool", "-l"]:
                        return paths
                    if args[0] == "nm":
                        return symbols
                    if args[0] == "codesign":
                        return ""
                    raise AssertionError(args)

                with patch.object(package, "run", side_effect=output):
                    if message:
                        with self.assertRaisesRegex(RuntimeError, message):
                            package.check_library(self.root / "lib", "arm64", header)
                    else:
                        self.assertEqual(
                            package.check_library(self.root / "lib", "arm64", header),
                            [dependency],
                        )


if __name__ == "__main__":
    unittest.main()
