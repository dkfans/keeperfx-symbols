#!/usr/bin/env python3
"""Turns keeperfx.exe.debug into a small symbol table the website's crash viewer
can fetch: function addresses plus a compressed address -> file:line table.

Usage: make_table.py <keeperfx.exe.debug> <build name> <commit sha> <out.sym.gz>

Output (gzip-compressed text):
    KFXSYM 1
    build <name>
    commit <sha>
    image_base <hex>
    files <n>          then n lines: repo-relative path (or absolute for system files)
    funcs <n>          then n lines: <addr hex> <size hex> <name>
    lines <n>          then n lines: <addr delta base36> <line base36> [<file index base36>]
                       file index is only written when it changes; line 0 marks a gap
"""
import gzip
import os
import re
import subprocess
import sys

OBJDUMP = os.environ.get("OBJDUMP", "i686-w64-mingw32-objdump")
NM = os.environ.get("NM", "i686-w64-mingw32-nm")
REPO_ROOT = re.compile(r"^.*?/keeperfx/keeperfx/")  # CI checkout path, Linux or Windows runner


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, errors="replace").stdout


def b36(n):
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    if n == 0:
        return "0"
    out = ""
    while n:
        n, r = divmod(n, 36)
        out = digits[r] + out
    return out


def repo_path(path):
    path = path.replace("\\", "/")
    stripped = REPO_ROOT.sub("", path)
    return os.path.normpath(stripped).replace("\\", "/") if stripped != path else path


def image_base(debug_file):
    m = re.search(r"^ImageBase\s+([0-9a-fA-F]+)", run(OBJDUMP, "-p", debug_file), re.M)
    return int(m.group(1), 16) if m else 0x400000


def file_tables(debug_file):
    """Per compile unit: {basename: full path}, from the raw line program headers."""
    units = []
    dirs, files, section = [], {}, None
    entry = re.compile(r"^\s+(\d+)\s+(.*)$")
    for line in run(OBJDUMP, "-w", "--dwarf=rawline", debug_file).splitlines():
        if line.startswith("  Offset:"):
            if dirs or files:
                units.append(files)
            dirs, files, section = [], {}, None
        elif "The Directory Table" in line:
            section = "dirs"
        elif "The File Name Table" in line:
            section = "files"
        elif line.strip().startswith("Entry") or not line.strip():
            if not line.strip():
                section = None
        elif section:
            m = entry.match(line)
            if not m:
                section = None
                continue
            # "(line_strp)	(offset: 0x..): name" or "(udata)	1	(line_strp)	(offset: ..): name"
            name = m.group(2).rsplit("): ", 1)[-1].strip()
            if section == "dirs":
                dirs.append(name)
            else:
                dir_index = re.match(r"\(udata\)\s+(\d+)", m.group(2))
                d = dirs[int(dir_index.group(1))] if dir_index and int(dir_index.group(1)) < len(dirs) else ""
                full = name if name.startswith("/") or not d else d + "/" + name
                files.setdefault(os.path.basename(name), full)
    if dirs or files:
        units.append(files)
    return units


def line_rows(debug_file, units):
    """Yields (address, full path or None, line) in address order within each unit."""
    row = re.compile(r"^(\S+)\s+(\d+|-)\s+(0x[0-9a-f]+)")
    unit = -1
    for line in run(OBJDUMP, "-w", "--dwarf=decodedline", debug_file).splitlines():
        if line.startswith("CU: "):
            unit += 1
            continue
        m = row.match(line)
        if not m or unit < 0:
            continue
        name, number, addr = m.groups()
        table = units[unit] if unit < len(units) else {}
        path = name if name.startswith("/") else table.get(os.path.basename(name), name)
        yield int(addr, 16), path, (0 if number == "-" else int(number))


def functions(debug_file):
    funcs = []
    for line in run(NM, "-n", "-C", "--defined-only", debug_file).splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3 and parts[1] in ("T", "t") and not parts[2].startswith("."):
            funcs.append((int(parts[0], 16), parts[2]))
    funcs.sort()
    out = []
    for i, (addr, name) in enumerate(funcs):
        size = funcs[i + 1][0] - addr if i + 1 < len(funcs) else 0
        if out and out[-1][0] == addr:
            continue  # aliases: keep the first name
        out.append((addr, size, name))
    return out


def main():
    debug_file, build, commit, out_path = sys.argv[1:5]

    units = file_tables(debug_file)
    by_addr = {}
    for addr, path, line in line_rows(debug_file, units):
        by_addr[addr] = (repo_path(path), line)  # several rows can share an address: keep the last

    files, file_index, rows = [], {}, []
    prev = None
    for addr in sorted(by_addr):
        path, line = by_addr[addr]
        if prev == (path, line):
            continue
        prev = (path, line)
        if path not in file_index:
            file_index[path] = len(files)
            files.append(path)
        rows.append((addr, file_index[path], line))

    funcs = functions(debug_file)

    out = ["KFXSYM 1", f"build {build}", f"commit {commit}", f"image_base {image_base(debug_file):x}",
           f"files {len(files)}", *files, f"funcs {len(funcs)}"]
    out += [f"{a:x} {s:x} {n}" for a, s, n in funcs]
    out.append(f"lines {len(rows)}")
    last_addr, last_file = 0, -1
    for addr, f, line in rows:
        text = f"{b36(addr - last_addr)} {b36(line)}"
        if f != last_file:
            text += f" {b36(f)}"
            last_file = f
        out.append(text)
        last_addr = addr

    with gzip.open(out_path, "wt", compresslevel=9, newline="\n") as fh:
        fh.write("\n".join(out) + "\n")
    print(f"{out_path}: {len(files)} files, {len(funcs)} functions, {len(rows)} line rows")


if __name__ == "__main__":
    main()
