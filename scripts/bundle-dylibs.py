#!/usr/bin/env python3
"""Copy every non-system dylib the app needs (libmpv and its Homebrew dependencies)
into Encore.app/Contents/Frameworks and rewrite all load paths to point there, so the
app runs on a Mac without Homebrew.

Usage: python3 scripts/bundle-dylibs.py build/Encore.app
"""
import os
import re
import shutil
import subprocess
import sys

app = sys.argv[1]
exe = os.path.join(app, "Contents/MacOS/Encore")
fw = os.path.join(app, "Contents/Frameworks")
os.makedirs(fw, exist_ok=True)
BUNDLED = "@executable_path/../Frameworks/"


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def deps(path):
    return [line.strip().split(" (")[0] for line in run("otool", "-L", path).splitlines()[1:]]


def rpaths(path):
    return re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+)", run("otool", "-l", path))


def is_system(ref):
    return ref.startswith("/usr/lib/") or ref.startswith("/System/")


def resolve(ref, referrer, referrer_origin):
    """Where a load command actually points, using the referrer's original location."""
    if ref.startswith("@rpath/"):
        for rp in rpaths(referrer):
            cand = os.path.join(rp.replace("@loader_path", os.path.dirname(referrer_origin)), ref[len("@rpath/"):])
            if os.path.exists(cand):
                return os.path.realpath(cand)
        return None
    if ref.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(os.path.dirname(referrer_origin), ref[len("@loader_path/"):]))
    if ref.startswith("@executable_path/"):
        return None  # already bundled
    return os.path.realpath(ref) if os.path.exists(ref) else None


# Walk the dependency graph from the executable, copying each library once.
copied = {}  # real source path -> bundled file name
queue = [(exe, exe)]  # (file in bundle, where it originally lived)
pending_rewrites = []  # (file in bundle, original ref, bundled name)
while queue:
    path, origin = queue.pop()
    for ref in deps(path):
        if is_system(ref):
            continue
        real = resolve(ref, path, origin)
        if real is None:
            if not ref.startswith("@executable_path/"):
                sys.exit(f"error: can't resolve {ref} (needed by {os.path.basename(path)})")
            continue
        if os.path.basename(real) == os.path.basename(path):
            continue  # a library's own install name
        name = os.path.basename(real)
        if real not in copied:
            dest = os.path.join(fw, name)
            shutil.copy2(real, dest)
            os.chmod(dest, 0o755)
            copied[real] = name
            queue.append((dest, real))
        pending_rewrites.append((path, ref, copied[real]))

# Point every load command at the bundled copies and give each library a bundled id.
for path, ref, name in pending_rewrites:
    run("install_name_tool", "-change", ref, BUNDLED + name, path)
for name in set(copied.values()):
    dest = os.path.join(fw, name)
    run("install_name_tool", "-id", BUNDLED + name, dest)
    for rp in rpaths(dest):
        if rp.startswith("/opt/homebrew") or rp.startswith("/usr/local"):
            run("install_name_tool", "-delete_rpath", rp, dest)
for rp in rpaths(exe):
    if rp.startswith("/opt/homebrew") or rp.startswith("/usr/local"):
        run("install_name_tool", "-delete_rpath", rp, exe)

# Nothing may still point outside the bundle.
leaks = []
for f in [exe] + [os.path.join(fw, n) for n in os.listdir(fw)]:
    for ref in deps(f):
        if not is_system(ref) and not ref.startswith(BUNDLED):
            leaks.append(f"{os.path.basename(f)} -> {ref}")
if leaks:
    sys.exit("error: still linked outside the app:\n  " + "\n  ".join(leaks))

size = sum(os.path.getsize(os.path.join(fw, n)) for n in os.listdir(fw)) / 1e6
print(f"Bundled {len(copied)} libraries ({size:.0f} MB) into Contents/Frameworks")
