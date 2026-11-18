#!/usr/bin/env python3
"""Build and verify a self-contained macOS Lite C API archive."""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD_OPTIONS = {
    "CMAKE_BUILD_TYPE": "Release",
    "NEUG_LITE": "ON",
    "BUILD_COMPILER": "ON",
    "NEUG_PACKAGE_BUILD": "ON",
    "NEUG_NATIVE_ARCH": "OFF",
    "BUILD_PYTHON": "OFF",
    "BUILD_NODEJS": "OFF",
    "BUILD_HTTP_SERVER": "OFF",
    "BUILD_EXTENSIONS": "",
    "NEUG_EXTENSION_CONFIGS": "",
    "WITH_MIMALLOC": "OFF",
    "ENABLE_BACKTRACES": "OFF",
    "BUILD_TEST": "OFF",
    "BUILD_EXAMPLES": "OFF",
    "BUILD_EXECUTABLES": "OFF",
    "BUILD_DOC": "OFF",
    "BUILD_SINGLE_FILE_HEADER": "OFF",
    "BUILD_SHARED_LIBS": "OFF",
    "ENABLE_GCOV": "OFF",
    "ENABLE_ADDRESS_SANITIZER": "OFF",
    "ENABLE_THREAD_SANITIZER": "OFF",
    "ENABLE_UBSAN": "OFF",
    "ENABLE_RUNTIME_CHECKS": "OFF",
}
PAYLOAD = {
    "include/neug/c/neug.h",
    "lib/libneug.dylib",
    "examples/basic.c",
    "examples/verify.c",
    "examples/CMakeLists.txt",
    "README.md",
    "LICENSE",
}


def run(args, cwd=None, env=None, log=None):
    if log:
        print(f"Running {args[0]} (log: {log})", flush=True)
        with Path(log).open("w") as stream:
            result = subprocess.run(
                args, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT
            )
        if result.returncode:
            raise RuntimeError(f"Command failed; see {log}")
        return ""
    return subprocess.check_output(args, cwd=cwd, env=env, text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_cache(path):
    return dict(
        re.findall(
            r"^([A-Za-z_][A-Za-z0-9_]*):[^=\r\n]+=(.*)$",
            path.read_text(),
            re.M,
        )
    )


def host_arch():
    if platform.system() != "Darwin" or platform.machine() not in (
        "arm64",
        "x86_64",
    ):
        raise RuntimeError("This entry point currently supports native macOS only")
    return platform.machine()


def rpaths(library):
    return re.findall(
        r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset",
        run(["otool", "-l", str(library)]),
    )


def check_library(library, arch, header):
    if run(["lipo", "-archs", str(library)]) != arch:
        raise RuntimeError("Library architecture does not match the package")
    names = [
        line.strip().split(" (compatibility version", 1)[0]
        for line in run(["otool", "-L", str(library)]).splitlines()[1:]
    ]
    if not names or names[0] != "@rpath/libneug.dylib":
        raise RuntimeError("Library install name must be @rpath/libneug.dylib")
    dependencies = names[1:]
    unexpected = [
        name
        for name in dependencies
        if not name.startswith(("/usr/lib/", "/System/Library/Frameworks/"))
    ]
    if unexpected:
        raise RuntimeError(f"Non-system dynamic dependencies: {unexpected}")
    if rpaths(library):
        raise RuntimeError("Packaged library must not retain build-time rpaths")
    declarations = set(re.findall(r"\b(neug_\w+)\s*\(", header.read_text()))
    exported = {
        line.split()[-1][1:]
        for line in run(["nm", "-gU", str(library)]).splitlines()
        if line.split() and line.split()[-1].startswith("_neug_")
    }
    if declarations != exported:
        raise RuntimeError(
            f"C exports differ: missing={declarations - exported}, "
            f"extra={exported - declarations}"
        )
    includes = re.findall(r"^#include\s+(.+)$", header.read_text(), re.M)
    if includes != ["<stddef.h>", "<stdint.h>"]:
        raise RuntimeError("C header has unexpected include dependencies")
    run(["codesign", "--verify", "--strict", str(library)])
    return dependencies


def extract_package(archive, destination):
    # Only regular files/directories under one root; never follow archive links.
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        roots = set()
        seen = set()
        for member in members:
            path = Path(member.name)
            if (
                path.is_absolute()
                or ".." in path.parts
                or not path.parts
                or not (member.isfile() or member.isdir())
                or member.name in seen
            ):
                raise RuntimeError(f"Invalid archive member: {member.name}")
            roots.add(path.parts[0])
            seen.add(member.name)
        if len(roots) != 1:
            raise RuntimeError("Archive must have one top-level directory")
        for member in members:
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, target.open("wb") as out:
                    shutil.copyfileobj(source, out)
                target.chmod(member.mode & 0o755)
    return destination / roots.pop()


def verify(archive, work_dir):
    arch = host_arch()
    archive = archive.resolve()
    expected = archive.with_name(archive.name + ".sha256").read_text().split()[0]
    if sha256(archive) != expected:
        raise RuntimeError("Archive SHA256 mismatch")
    work_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="verify-", dir=work_dir))
    package = extract_package(archive, work)
    metadata = json.loads((package / "manifest.json").read_text())
    actual = {str(p.relative_to(package)) for p in package.rglob("*") if p.is_file()}
    if actual != PAYLOAD | {"manifest.json"}:
        raise RuntimeError(f"Unexpected package contents: {actual}")
    if set(metadata["files"]) != PAYLOAD:
        raise RuntimeError("Manifest file list differs from the package contract")
    for name, digest in metadata["files"].items():
        if sha256(package / name) != digest:
            raise RuntimeError(f"File SHA256 mismatch: {name}")
    if metadata["platform"] != f"osx-{arch}":
        raise RuntimeError("This package does not match the verification host")
    dependencies = check_library(
        package / "lib/libneug.dylib", arch, package / "include/neug/c/neug.h"
    )
    if dependencies != metadata["system_dependencies"]:
        raise RuntimeError("Dependency manifest does not match the library")

    # Do not let a developer's installed NeuG or compiler search paths mask a
    # missing dependency. Tests use only the extracted package and OS SDK.
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("DYLD_") or key in {
            "CPATH",
            "C_INCLUDE_PATH",
            "CPLUS_INCLUDE_PATH",
            "LIBRARY_PATH",
            "LD_LIBRARY_PATH",
            "CMAKE_PREFIX_PATH",
            "CMAKE_INCLUDE_PATH",
            "CMAKE_LIBRARY_PATH",
            "CMAKE_FRAMEWORK_PATH",
            "CMAKE_TOOLCHAIN_FILE",
            "CC",
            "CXX",
            "CFLAGS",
            "CPPFLAGS",
            "CXXFLAGS",
            "LDFLAGS",
            "SDKROOT",
        }:
            del env[key]
    summary = {
        "archive": str(archive),
        "sha256": expected,
        "host": {"platform": f"osx-{arch}", "macos_version": platform.mac_ver()[0]},
        "tests": [],
    }
    basic_build = work / "basic-build"
    run(
        [
            "cmake",
            "-S",
            str(package / "examples"),
            "-B",
            str(basic_build),
            "-DCMAKE_PREFIX_PATH=" + str(package),
        ],
        cwd=work,
        env=env,
        log=work / "basic-configure.log",
    )
    cache = read_cache(basic_build / "CMakeCache.txt")
    if cache.get("NEUG_INCLUDE_DIR") != str(package / "include") or cache.get(
        "NEUG_LIBRARY"
    ) != str(package / "lib/libneug.dylib"):
        raise RuntimeError("Example resolved files outside the extracted package")
    run(
        ["cmake", "--build", str(basic_build), "--parallel", "1"],
        cwd=work,
        env=env,
        log=work / "basic-build.log",
    )
    basic_log = work / "basic-run.log"
    run([str(basic_build / "neug_c_example")], cwd=work, env=env, log=basic_log)
    if "1 | O'Connor" not in basic_log.read_text().splitlines():
        raise RuntimeError("Basic example returned unexpected output")
    summary["tests"].append({"case": "cmake-basic-example", "status": "passed"})
    for language, compiler, standard in (
        ("c", "clang", "c11"),
        ("c++", "clang++", "c++17"),
    ):
        executable = work / ("verify-c" if language == "c" else "verify-cpp")
        run(
            [
                "xcrun",
                compiler,
                "-x",
                language,
                f"-std={standard}",
                "-Wall",
                "-Werror",
                "-I" + str(package / "include"),
                str(package / "examples/verify.c"),
                "-L" + str(package / "lib"),
                "-lneug",
                "-Wl,-rpath," + str(package / "lib"),
                "-o",
                str(executable),
            ],
            cwd=work,
            env=env,
            log=work / (executable.name + "-build.log"),
        )
        for phase in ("write", "read"):
            log = work / (executable.name + "-" + phase + ".log")
            run(
                [
                    str(executable),
                    str(work / (executable.name + "-db")),
                    metadata["version"],
                    phase,
                ],
                cwd=work,
                env=env,
                log=log,
            )
            if f"PASS: C API package {phase}" not in log.read_text():
                raise RuntimeError(f"Missing verification result: {log}")
            summary["tests"].append(
                {"language": language, "phase": phase, "status": "passed"}
            )
    summary["system_dependencies"] = dependencies
    (work / "verification.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Verified extracted package: {package}", flush=True)
    print(f"Verification report: {work / 'verification.json'}", flush=True)
    return work


def build(args):
    arch = host_arch()
    build_dir = args.build_dir.resolve()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="build-", dir=output_dir))
    try:
        cores = int(run(["sysctl", "-n", "hw.physicalcpu"]))
    except (subprocess.CalledProcessError, ValueError):
        cores = 1
    jobs = min(args.jobs, cores)
    if jobs < 1:
        raise RuntimeError("jobs must be positive")
    options = dict(BUILD_OPTIONS)
    options["CMAKE_OSX_ARCHITECTURES"] = arch
    options["CMAKE_OSX_DEPLOYMENT_TARGET"] = args.deployment_target
    print(f"Building macOS {arch} Lite C API with {jobs} parallel jobs", flush=True)
    run(
        ["cmake", "-S", str(ROOT), "-B", str(build_dir)]
        + [f"-D{key}={value}" for key, value in options.items()],
        log=logs / "configure.log",
    )
    cache = read_cache(build_dir / "CMakeCache.txt")
    for key, value in options.items():
        if cache.get(key) != value:
            raise RuntimeError(f"Unexpected build setting: {key}={cache.get(key)}")
    run(
        [
            "cmake",
            "--build",
            str(build_dir),
            "--target",
            "neug",
            "--config",
            "Release",
            "--parallel",
            str(jobs),
        ],
        log=logs / "build.log",
    )
    version = (ROOT / "NEUG_VERSION").read_text().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+-]*", version):
        raise RuntimeError("Invalid release version")
    name = f"neug-c-api-{version}-lite-osx-{arch}"
    stage = logs / name
    (stage / "include/neug/c").mkdir(parents=True)
    (stage / "lib").mkdir()
    (stage / "examples").mkdir()
    shutil.copyfile(ROOT / "include/neug/c/neug.h", stage / "include/neug/c/neug.h")
    library = stage / "lib/libneug.dylib"
    shutil.copyfile(build_dir / "src/libneug.dylib", library)
    run(["install_name_tool", "-id", "@rpath/libneug.dylib", str(library)])
    for path in rpaths(library):
        run(["install_name_tool", "-delete_rpath", path, str(library)])
    run(["strip", "-x", str(library)])
    run(["codesign", "--force", "--sign", "-", str(library)])
    library.chmod(0o755)
    dependencies = check_library(library, arch, stage / "include/neug/c/neug.h")
    for filename in ("basic.c", "verify.c", "CMakeLists.txt"):
        shutil.copyfile(ROOT / "examples/c" / filename, stage / "examples" / filename)
    shutil.copyfile(ROOT / "examples/c/README.md", stage / "README.md")
    shutil.copyfile(ROOT / "LICENSE", stage / "LICENSE")
    metadata = {
        "version": version,
        "variant": "lite",
        "platform": f"osx-{arch}",
        "deployment_target": args.deployment_target,
        "c_api_version": int(
            re.search(
                r"#define NEUG_C_API_VERSION (\d+)",
                (stage / "include/neug/c/neug.h").read_text(),
            ).group(1)
        ),
        "source_commit": run(["git", "rev-parse", "HEAD"], cwd=ROOT),
        "source_has_local_changes": bool(
            run(["git", "status", "--porcelain"], cwd=ROOT)
        ),
        "build_options": options,
        "system_dependencies": dependencies,
        "files": {name: sha256(stage / name) for name in sorted(PAYLOAD)},
    }
    (stage / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
    archive = logs / (name + ".tar.gz")
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(stage, arcname=name)
    checksum = archive.with_name(archive.name + ".sha256")
    checksum.write_text(f"{sha256(archive)}  {archive.name}\n")
    verify(archive, output_dir)
    # Only promote an archive after its extracted contents pass verification.
    shutil.copyfile(archive, output_dir / archive.name)
    shutil.copyfile(checksum, output_dir / checksum.name)
    print(f"Package: {output_dir / archive.name}", flush=True)
    print(f"SHA256: {output_dir / checksum.name}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pack = commands.add_parser("build", help="Build, package, and verify macOS Lite")
    pack.add_argument("--build-dir", type=Path, default=ROOT / "build")
    pack.add_argument("--output-dir", type=Path, default=ROOT / "build/c-api-dist")
    pack.add_argument("--jobs", type=int, default=2)
    pack.add_argument("--deployment-target", default="11.0")
    check = commands.add_parser(
        "verify", help="Verify an existing archive and checksum"
    )
    check.add_argument("archive", type=Path)
    check.add_argument("--work-dir", type=Path, default=ROOT / "build/c-api-dist")
    args = parser.parse_args()
    if args.command == "build":
        build(args)
    else:
        verify(args.archive, args.work_dir.resolve())


if __name__ == "__main__":
    main()
