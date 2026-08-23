#!/usr/bin/env python3
"""撮影結果（.xcresult の添付）を名前つき PNG として取り出す。
使い方: python3 scripts/export_screenshots.py [xcresult] [outdir]"""
import json, os, re, shutil, subprocess, sys

xcresult = sys.argv[1] if len(sys.argv) > 1 else ".screenshot_assets/result.xcresult"
outdir = sys.argv[2] if len(sys.argv) > 2 else ".screenshot_assets/shots"
tmp = ".screenshot_assets/_export"

shutil.rmtree(tmp, ignore_errors=True)
shutil.rmtree(outdir, ignore_errors=True)
subprocess.run(["xcrun", "xcresulttool", "export", "attachments",
                "--path", xcresult, "--output-path", tmp],
               check=True, stdout=subprocess.DEVNULL)
os.makedirs(outdir, exist_ok=True)

manifest = json.load(open(os.path.join(tmp, "manifest.json")))
seen = set()

def walk(node):
    if isinstance(node, dict):
        name = node.get("suggestedHumanReadableName", "")
        exported = node.get("exportedFileName", "")
        if re.match(r"^\d\d[a-z]?-", name) and exported.endswith(".png"):
            base = name.split("_")[0]
            if base not in seen:
                seen.add(base)
                shutil.copy(os.path.join(tmp, exported), os.path.join(outdir, base + ".png"))
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)

walk(manifest)
shutil.rmtree(tmp, ignore_errors=True)
print("\n".join(sorted(seen)) or "no screenshots found")
