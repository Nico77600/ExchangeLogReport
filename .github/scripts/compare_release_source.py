#!/usr/bin/env python3
"""Compares a release ZIP with the tagged source and the pinned third-party binaries.

Every file of the ZIP must be accounted for, and nothing else may be in it:
  * a file that comes from the repository equals the file at the tag (see below for line endings);
  * the six signed PowerShell files and PackageIntegrity.psd1 equal the file at the tag up to the Authenticode signature
    block, and the block is the only difference;
  * powershell/ equals the pinned PowerShell archive of product.json, without its .pdb files;
  * sqlite-tools/sqlite3.exe and the files of lib/sqlite equal the SHA-256 pins of product.json.
No source file is executed and nothing is built. The only download is the pinned PowerShell archive, checked against its SHA-256.

Line endings: the package builder copies the working tree of the owner's machine, where core.autocrlf turns the lone LF of
a text blob into CRLF. A file is therefore accepted when it equals the blob, or the blob with every lone LF turned into CRLF.
Files marked -text in .gitattributes and files that contain a NUL byte must equal the blob byte for byte.

Usage: compare_release_source.py --zip ZIP --source CHECKED_OUT_TAG [--tag vX.Y.Z] [--powershell-archive ARCHIVE] [--output REPORT.json]
Exit status 0 only when the ZIP is exactly the tagged source plus the pinned binaries.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

SIGNED_SCRIPTS = (
    "Invoke-ExchangeLogReport.ps1", "Database-Storage.ps1", "ExchangeLogReport.psm1", "ExchangeLogReport.psd1",
    "src/Test-PackageIntegrity.ps1", "src/Get-ExlExchangeSettings.ps1",
)
SIGNED_FILES = SIGNED_SCRIPTS + ("PackageIntegrity.psd1",)
SIGNATURE_BEGIN = b"# SIG # Begin signature block"
SIGNATURE_END = b"# SIG # End signature block"
# Mirrors tools/Build-Standalone.ps1: what the builder leaves out of package\ and what it adds from outside it.
BUILDER_EXCLUDED_TOP_FOLDERS = ("bin", "data", "logs", "reports", "host", "powershell", "sqlite-tools")
BUILDER_ROOT_FILES = ("product.json", "LICENSE", "SECURITY.md", "CHANGELOG.md")
BUILDER_SQLITE_TOOLS_FILES = {"sqlite-tools/NOTICE.txt": "lib/sqlite-tools/NOTICE.txt"}
BUILDER_SQLITE_TOOLS_EXECUTABLE = "sqlite-tools/sqlite3.exe"
# Files the builder creates itself and that exist nowhere else: none. The SBOM is a separate release asset.
BUILDER_GENERATED_FILES = ()
LIMIT_BYTES = 2 * 1024 * 1024 * 1024


class Mismatch(Exception):
    pass


def sha256_stream(stream):
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def sha256_file(path):
    with open(path, "rb") as stream:
        return sha256_stream(stream)


def zip_path(value):
    if not isinstance(value, str) or not value or "\x00" in value:
        raise Mismatch("Invalid ZIP path")
    value = value.replace("\\", "/")
    if value.startswith("/") or ":" in value or any(part in ("", ".", "..") for part in value.split("/")):
        raise Mismatch(f"Unsafe ZIP path: {value}")
    return value


def read_zip_files(archive):
    files = {}
    seen = set()
    total = 0
    for entry in archive.infolist():
        name = zip_path(entry.filename.rstrip("/") if entry.is_dir() else entry.filename)
        if name.casefold() in seen:
            raise Mismatch(f"Duplicate or case-colliding ZIP entry: {name}")
        seen.add(name.casefold())
        if entry.flag_bits & 1 or stat.S_ISLNK(entry.external_attr >> 16):
            raise Mismatch("Encrypted ZIP entries and symlinks are not supported")
        if entry.is_dir():
            continue
        total += entry.file_size
        if total > LIMIT_BYTES:
            raise Mismatch("ZIP uncompressed size exceeds the reviewed limit")
        files[name] = entry
    if not files:
        raise Mismatch("The ZIP is empty")
    roots = {name.split("/")[0] for name in files}
    if len(roots) != 1 or any("/" not in name for name in files):
        raise Mismatch("The ZIP must hold exactly one package folder")
    prefix = roots.pop() + "/"
    return prefix, {name[len(prefix):]: entry for name, entry in files.items()}


def git(source, *arguments, data=None):
    result = subprocess.run(["git", "-C", str(source), *arguments], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise Mismatch(f"git {arguments[0]} failed: {result.stderr.decode('utf-8', 'replace').strip()}")
    return result.stdout


def tracked_files(source):
    return sorted(name for name in git(source, "ls-files", "-z").decode("utf-8").split("\x00") if name)


def unset_text_files(source, names):
    flagged = set()
    if not names:
        return flagged
    output = git(source, "check-attr", "-z", "--stdin", "text", data="\x00".join(names).encode("utf-8") + b"\x00")
    parts = output.decode("utf-8").split("\x00")
    for index in range(0, len(parts) - 2, 3):
        if parts[index + 2] == "unset":
            flagged.add(parts[index])
    return flagged


def package_relative(name):
    """The package-relative path of a tracked package/ file, or None when the builder leaves it out."""
    if not name.startswith("package/"):
        return None
    relative = name[len("package/"):]
    if relative.split("/")[0] in BUILDER_EXCLUDED_TOP_FOLDERS:
        return None
    if relative.startswith("docs/") and relative.endswith(".md"):
        return None
    if relative.startswith("docs/images/"):
        return None
    file_name = relative.rsplit("/", 1)[-1]
    if file_name.lower().endswith(".paths.psd1") or file_name.lower().endswith(".credential"):
        return None
    return relative


def lone_lf_to_crlf(data):
    return re.sub(rb"(?<!\r)\n", b"\r\n", data)


def split_signature(data):
    index = data.find(SIGNATURE_BEGIN)
    if index < 0:
        return data, None
    return data[:index], data[index:]


def signature_block_problem(block):
    """None when the block is exactly an Authenticode signature block: the begin line, base64 comment lines, the end line, nothing after."""
    lines = block.replace(b"\r\n", b"\n").split(b"\n")
    if lines[0] != SIGNATURE_BEGIN:
        return "the signature block does not start on its own line"
    try:
        end = lines.index(SIGNATURE_END)
    except ValueError:
        return "the signature block is not terminated"
    for line in lines[1:end]:
        if not re.fullmatch(rb"# [A-Za-z0-9+/=]+", line):
            return "the signature block holds a line that is not signature data"
    if any(line.strip() for line in lines[end + 1:]):
        return "there is text after the signature block"
    return None


def compare_signed(zip_bytes, source_bytes):
    zip_body, zip_block = split_signature(zip_bytes)
    source_body, source_block = split_signature(source_bytes)
    if zip_block is None:
        return "the ZIP file carries no Authenticode signature block"
    if zip_body and not zip_body.endswith(b"\n"):
        return "the signature block does not start on its own line"
    problem = signature_block_problem(zip_block)
    if problem:
        return f"{problem} in the ZIP file"
    if zip_body.rstrip(b"\r\n") != source_body.rstrip(b"\r\n"):
        return "the content before the signature block differs from the tag"
    if source_block is not None:
        problem = signature_block_problem(source_block)
        if problem:
            return f"{problem} at the tag"
    return None


def load_powershell_members(product, archive_path):
    expected = product["powerShell"]["sha256"].lower()
    scratch = None
    try:
        if archive_path is None:
            request = urllib.request.Request(product["powerShell"]["url"], headers={"User-Agent": "release-source-comparison"})
            scratch = tempfile.mkdtemp(prefix="powershell-archive-")
            archive_path = os.path.join(scratch, "PowerShell.zip")
            with urllib.request.urlopen(request, timeout=300) as response, open(archive_path, "xb") as output:
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    output.write(chunk)
        if sha256_file(archive_path) != expected:
            raise Mismatch("The PowerShell archive does not match its SHA-256 pin in product.json")
        members = {}
        with zipfile.ZipFile(archive_path) as archive:
            for entry in archive.infolist():
                if entry.is_dir():
                    continue
                name = zip_path(entry.filename)
                if name.lower().endswith(".pdb"):
                    continue
                with archive.open(entry) as stream:
                    members["powershell/" + name] = sha256_stream(stream)
    finally:
        if scratch is not None:
            shutil.rmtree(scratch, ignore_errors=True)
    if "powershell/pwsh.exe" not in members:
        raise Mismatch("The PowerShell archive has no pwsh.exe")
    return members


def compare(zip_file, source, tag=None, powershell_archive=None):
    problems = []
    notes = {"line_ending_conversions": [], "signature_only_differences": []}
    source = Path(source)
    if tag is not None:
        head = git(source, "rev-parse", "HEAD").decode().strip()
        tagged = git(source, "rev-parse", f"refs/tags/{tag}^{{commit}}").decode().strip()
        if head != tagged:
            raise Mismatch("The source folder is not the exact tag")
    if git(source, "status", "--porcelain", "--untracked-files=no").strip():
        raise Mismatch("The source folder has modifications against the tag")
    product = json.loads((source / "product.json").read_text(encoding="utf-8-sig"))
    if tag is not None and product.get("version") != tag[1:]:
        raise Mismatch("product.json at the tag does not carry the tag version")

    with zipfile.ZipFile(zip_file) as archive:
        prefix, files = read_zip_files(archive)
        repository = {}
        names = tracked_files(source)
        for name in names:
            relative = package_relative(name)
            if relative is not None:
                repository[relative] = name
        for name in BUILDER_ROOT_FILES:
            if name not in names:
                raise Mismatch(f"{name} is not tracked at the tag")
            repository[name] = name
        for packaged, tracked in BUILDER_SQLITE_TOOLS_FILES.items():
            if tracked not in names:
                raise Mismatch(f"{tracked} is not tracked at the tag")
            repository[packaged] = tracked
        if "PackageIntegrity.psd1" not in repository:
            raise Mismatch("The signed manifest package/PackageIntegrity.psd1 is not committed at the tag")
        for name in SIGNED_SCRIPTS:
            if name not in repository:
                raise Mismatch(f"The signed script {name} is not tracked at the tag")

        pins = {BUILDER_SQLITE_TOOLS_EXECUTABLE: product["sqliteTools"]["executableSha256"].lower()}
        for library in (product.get("sqliteLibraries") or {}).get("packages", []):
            for file in library["files"]:
                pins["lib/sqlite/" + file["path"]] = file["sha256"].lower()
        shipped = load_powershell_members(product, powershell_archive)

        expected = set(repository) | set(pins) | set(shipped) | set(BUILDER_GENERATED_FILES)
        for name in sorted(set(files) - expected):
            problems.append(f"In the ZIP but in neither the tag nor the pins: {name}")
        for name in sorted(expected - set(files)):
            problems.append(f"Expected from the tag or the pins but missing from the ZIP: {name}")
        unset_text = unset_text_files(source, sorted(set(repository.values())))

        for name in sorted(set(files) & expected):
            entry = files[name]
            if name in repository:
                blob = (source / repository[name]).read_bytes()
                with archive.open(entry) as stream:
                    packed = stream.read()
                if packed == blob:
                    pass
                elif name in SIGNED_FILES:
                    reason = compare_signed(packed, blob)
                    if reason is None:
                        notes["signature_only_differences"].append(name)
                    else:
                        problems.append(f"Signed file differs from the tag: {name}: {reason}")
                elif repository[name] not in unset_text and b"\x00" not in blob[:8000] and packed == lone_lf_to_crlf(blob):
                    notes["line_ending_conversions"].append(name)
                else:
                    problems.append(f"File differs from the tag: {name}")
            if name in pins or name in shipped:
                with archive.open(entry) as stream:
                    actual = sha256_stream(stream)
                wanted = pins.get(name) or shipped.get(name)
                if actual != wanted:
                    problems.append(f"Third-party binary differs from its pin: {name}")
    return {
        "zip": os.path.basename(str(zip_file)),
        "tag": tag,
        "files": len(files),
        "from_repository": len([n for n in files if n in repository]),
        "from_pins": len([n for n in files if n in pins]),
        "from_powershell_archive": len([n for n in files if n in shipped]),
        "line_ending_conversions": len(notes["line_ending_conversions"]),
        "signature_only_differences": sorted(notes["signature_only_differences"]),
        "problems": problems,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--zip", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--tag")
    parser.add_argument("--powershell-archive")
    parser.add_argument("--output")
    arguments = parser.parse_args(argv)
    try:
        report = compare(arguments.zip, arguments.source, arguments.tag, arguments.powershell_archive)
    except (Mismatch, zipfile.BadZipFile, OSError, KeyError, ValueError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1
    if arguments.output:
        Path(arguments.output).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "problems"}))
    for problem in report["problems"][:50]:
        print(f"FAILED: {problem}", file=sys.stderr)
    if len(report["problems"]) > 50:
        print(f"FAILED: {len(report['problems']) - 50} more problem(s)", file=sys.stderr)
    return 1 if report["problems"] else 0


if __name__ == "__main__":
    sys.exit(main())
