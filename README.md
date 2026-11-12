# KeeperFX symbols

Debug symbols (`keeperfx.exe.debug`) for every [KeeperFX](https://github.com/dkfans/keeperfx) alpha and release build, kept so crash dumps can be read after GitHub's 90-day artifact expiry.

A workflow here checks dkfans/keeperfx every 3 hours and copies each new build's symbols into a monthly release (`symbols-YYYY-MM`). Prototype (PR) builds are not kept.

## Finding the right file

The first line of `keeperfx.log` names the build, e.g. `Dungeon Keeper FX ver 1.4.0.5601 Alpha`. The matching file is `keeperfx-1_4_0_5601-Alpha.exe.debug.xz`. Search [index.tsv](index.tsv) for the build number to see which release it's in.

The symbols only match the exact exe they were built with. A local or self-built exe needs its own `.debug` file from its build folder.

## Reading a crash dump

1. Unpack the `.xz` (7-Zip opens it) and put `keeperfx.exe.debug` next to the `keeperfx.exe` that crashed.
2. Open the `keeperfx_crash_*.dmp` in WinDbg and run `k` to list the stack. Without a PDB, frames show as `keeperfx+0x1a2b3c`.
3. Turn each offset into a function and line:

   ```
   i686-w64-mingw32-addr2line -f -C -i -e keeperfx.exe.debug 0x<0x400000 + offset>
   ```

   `0x400000` is the default image base; check it with `objdump -p keeperfx.exe.debug | grep ImageBase`.

The `keeperfx.map` file shipped with each build gives function names too, without line numbers.

## Symbol tables for the website

The `tables` branch holds a small `<build>.sym.gz` per build (functions, source lines and the commit it was built from), made by `make_table.py`. The crash report page on keeperfx.net fetches these from raw.githubusercontent.com to explain crash dumps in the browser. The branch is rewritten on each update, so don't base anything on it.
