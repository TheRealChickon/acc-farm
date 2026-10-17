"""Packs src/*.lua into dist/acc-farm.lua (one file, one download). Run after every change: python3 tools/bundle.py"""
import os, glob
mods = []
for path in sorted(glob.glob("src/**/*.lua", recursive=True)):
    name = os.path.relpath(path, "src")[:-4].replace(os.sep, "/")
    src = open(path, encoding="utf-8").read()
    eq = "=" * 3
    while ("]" + eq + "]") in src: eq += "="
    mods.append(f'M["{name}"] = [{eq}[\n{src}]{eq}]')
out = ["-- Card Clash Farm, bundled by tools/bundle.py. Source: src/. Returns {[module] = source}.", "local M = {}"] + mods + ["return M", ""]
os.makedirs("dist", exist_ok=True)
open("dist/acc-farm.lua", "w", encoding="utf-8").write("\n".join(out))
print("modules", len(mods), "bytes", os.path.getsize("dist/acc-farm.lua"))

src = open("loader.lua", encoding="utf-8").read()
open("tests/_loader.luau", "w", encoding="utf-8").write("return [====[\n" + src + "]====]\n")
