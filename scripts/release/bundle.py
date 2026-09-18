#!/usr/bin/env python3
"""Prepare and inspect a release bundle without launching the application."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def macho_files(app):
    return [p for p in sorted(app.rglob("*"))
            if p.is_file() and not p.is_symlink() and "Mach-O" in run("file", "-b", p)]


def prepare(app, packages, lame):
    helpers = app / "Contents/Helpers"
    helpers.mkdir(parents=True, exist_ok=True)
    shutil.copy2(lame / "lame", helpers / "lame")
    third_party = app / "Contents/Resources/ThirdParty"
    third_party.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "LICENSE", third_party / "Simple-Meeting-Scribe-LICENSE")
    target = third_party / "LAME"
    target.mkdir()
    archives = list(lame.glob("lame-*.tar.gz"))
    require(len(archives) == 1, "Expected one LAME source archive")
    for source in [lame / "COPYING", lame / "LICENSE", archives[0]]:
        shutil.copy2(source, target / source.name)
    (target / "scripts/release").mkdir(parents=True)
    shutil.copy2(ROOT / "scripts/build-lame.sh", target / "scripts/build-lame.sh")
    shutil.copy2(ROOT / "scripts/release/lame.env", target / "scripts/release/lame.env")
    (target / "README.txt").write_text(
        "This app uses LAME (https://lame.sourceforge.io/), LGPL-2.0-or-later.\n"
        "The encoder is a separate executable; the app communicates with it through files.\n"
        "The complete, unmodified source archive and license are included here.\n"
        "To rebuild on an Apple Silicon Mac with Xcode and pkgconf (build tools), copy this LAME directory\n"
        "to a writable location, cd into it, and run:\n"
        f"LAME_SOURCE_ARCHIVE=\"$PWD/{archives[0].name}\" bash scripts/build-lame.sh /tmp/rebuilt-lame\n"
        "Use a new output directory for each build. Replacing an executable inside\n"
        "a signed app invalidates its signature; build/sign your modified app yourself.\n"
    )
    pins = json.loads((ROOT / "scripts/release/Package.resolved").read_text())["pins"]
    checkouts = {p.name.lower(): p for p in (packages / "checkouts").iterdir() if p.is_dir()}
    for pin in pins:
        identity = pin["identity"]
        require(identity in checkouts, f"Missing package checkout: {identity}")
        checkout = checkouts[identity]
        require(run("git", "-C", checkout, "rev-parse", "HEAD") == pin["state"]["revision"],
                f"Package revision differs from lockfile: {identity}")
        require(not run("git", "-C", checkout, "status", "--porcelain", "--untracked-files=no"),
                f"Modified package checkout: {identity}")
        notices = [p for p in checkout.iterdir() if p.is_file() and
                   p.name.upper().startswith(("LICENSE", "COPYING", "NOTICE"))]
        require(notices, f"No license found for {identity}; review before distributing")
        destination = third_party / identity
        destination.mkdir()
        for notice in notices:
            shutil.copy2(notice, destination / notice.name)
        # Some dependencies include vendored code with additional notices.
        for notice in checkout.rglob("*"):
            if notice.is_file() and not notice.is_symlink() and notice.parent != checkout and \
                    notice.name.upper().startswith(("LICENSE", "COPYING", "NOTICE")) and \
                    ".git" not in notice.relative_to(checkout).parts:
                nested = destination / notice.relative_to(checkout)
                nested.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(notice, nested)
    shutil.copy2(ROOT / "scripts/release/Package.resolved", third_party / "Package.resolved")


def verify(app, signed=False):
    require(app.is_dir(), f"Missing app: {app}")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == "com.czlonkowski.MeetingTranscriber", "Unexpected bundle ID")
    require(info["LSMinimumSystemVersion"] == "26.0", "Unexpected minimum macOS version")
    require(info["CFBundlePackageType"] == "APPL", "Not an application bundle")
    for relative in ["Contents/Helpers/lame", "Contents/Resources/AppIcon.icns",
                     "Contents/Resources/meeting-patterns.json", "Contents/Resources/ThirdParty/LAME/COPYING"]:
        require((app / relative).is_file(), f"Missing release resource: {relative}")
    require(list(app.rglob("*.metallib")), "Missing MLX Metal library")
    require(not list(app.rglob("*.xctest")), "Test bundle included in release")
    for path in app.rglob("*"):
        if path.is_symlink():
            require(path.resolve().is_relative_to(app.resolve()), f"External bundle symlink: {path}")
        require(not any(word in path.name for word in (".debug.dylib", "__preview", "XCTest", "XCUIAutomation")),
                f"Debug/test runtime included: {path}")
    binaries = macho_files(app)
    require(app / "Contents/MacOS/MeetingTranscriber" in binaries, "Missing app executable")
    for binary in binaries:
        require(run("lipo", "-archs", binary) == "arm64", f"Unexpected architecture: {binary}")
        for line in run("otool", "-L", binary).splitlines()[1:]:
            dependency = line.strip().split(" (compatibility")[0]
            require(dependency.startswith(("/usr/lib/", "/System/Library/", "@rpath/", "@loader_path/", "@executable_path/")),
                    f"Nonportable dependency in {binary}: {dependency}")
        if signed:
            details = subprocess.run(["codesign", "-d", "--verbose=4", str(binary)],
                                     capture_output=True, text=True, check=True).stderr
            require("Authority=Developer ID Application:" in details, f"Not Developer ID signed: {binary}")
            require("runtime" in details and "Timestamp=" in details, f"Missing runtime/timestamp: {binary}")
            entitlements = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(binary)],
                                          capture_output=True, check=True).stdout
            if entitlements:
                require(not plistlib.loads(entitlements).get("com.apple.security.get-task-allow", False),
                        f"Debug entitlement present: {binary}")
    if signed:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=True)
    print(f"Verified {len(binaries)} arm64 executables and release resources in {app.name}")


def sign(app, identity):
    # Sign code inside-out. --deep is only for verification, never for signing.
    for binary in sorted(macho_files(app), key=lambda p: len(p.parts), reverse=True):
        if binary == app / "Contents/MacOS/MeetingTranscriber":
            continue
        subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp", "--options", "runtime", str(binary)], check=True)
    bundles = [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink() and
               p.suffix in (".framework", ".bundle", ".xpc", ".app")]
    for bundle in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp", "--options", "runtime", str(bundle)], check=True)
    subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp", "--options", "runtime",
                    "--entitlements", str(ROOT / "MeetingTranscriber/Resources/MeetingTranscriber.entitlements"), str(app)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    prep.add_argument("app", type=Path)
    prep.add_argument("packages", type=Path)
    prep.add_argument("lame", type=Path)
    check = sub.add_parser("verify")
    check.add_argument("app", type=Path)
    check.add_argument("--signed", action="store_true")
    signing = sub.add_parser("sign")
    signing.add_argument("app", type=Path)
    signing.add_argument("identity")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.app, args.packages, args.lame)
    elif args.command == "sign":
        sign(args.app, args.identity)
    else:
        verify(args.app, args.signed)


if __name__ == "__main__":
    main()
