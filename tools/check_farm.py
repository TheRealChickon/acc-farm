"""Checks that the Cyberpunk farm scripts in the executor workspace still keep the contract the farm window's Cyberpunk tab relies on
(src/tasks/cyberpunk.lua). Reads files only; nothing is run and nothing is changed.

    python tools/check_farm.py [workspace folder]      default: %LOCALAPPDATA%\\Potassium\\workspace\\AnimeCardClash

What the tab relies on (from the script's own header):
  start = loadstring(readfile(".../cyber_farm.lua"))(), alive = _G.__CF_RUNNING, stop = _G.__CF_STOP or "0" in cyber_farm.flag,
  test mode = _G.__CF_DRY, heartbeat = cyber_farm_hb.json with status "running" / "between runs" / "paused: ..." / "stopped: ...",
  one account table (folder, lock file, lock name) that must be the same as the tab's.
Run it after the Cyberpunk threads change cyber_farm.lua, and before relying on the tab.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TAB = os.path.join(HERE, "..", "src", "tasks", "cyberpunk.lua")
WORK = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("LOCALAPPDATA", ""), "Potassium", "workspace", "AnimeCardClash")

NEEDS = [
    ("_G.__CF_RUNNING = os.clock()", "refreshes the alive stamp"),
    ("_G.__CF_RUNNING = 0", "clears the stamp when it ends"),
    ("_G.__CF_STOP", "honours the stop flag"),
    ("_G.__CF_DRY", "honours test mode"),
    ("cyber_farm.flag", "reads the flag file"),
    ("cyber_farm_hb.json", "writes the heartbeat"),
    ("cyber_farm_cfg.json", "reads the settings file"),
    ('"stopped: "', "heartbeat says stopped: <reason> when it ends"),
    ('"paused: "', "heartbeat says paused: <reason> while it waits"),
    ('"between runs"', "heartbeat says between runs"),
    ("owner is ", "pause reason names the lock owner"),
    ("already running in this environment", "refuses a second copy in the same game"),
]
HB_KEYS = ["status", "act", "room", "highest", "eddies", "runs", "deaths", "buys", "sent", "up", "version", "dry", "t"]
ACC_RE = re.compile(r'(\w+)\s*=\s*\{\s*dir\s*=\s*"([^"]+)",\s*ownerFile\s*=\s*"([^"]+)",\s*owner\s*=\s*"([^"]+)"')


def accounts(text):
    return {m.group(1): (m.group(2), m.group(3), m.group(4)) for m in ACC_RE.finditer(text)}


def main():
    tab = open(TAB, encoding="utf-8").read()
    want = accounts(tab)
    print("tab accounts:", want)
    bad = 0
    files = []
    for sub in ("", "umson"):
        for name in ("cyber_farm.lua", "cyber_farm_prev.lua"):
            files.append(os.path.join(WORK, sub, name) if sub else os.path.join(WORK, name))
    for path in files:
        label = os.path.relpath(path, WORK)
        if not os.path.isfile(path):
            print("  missing   %s" % label)
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        ver = re.search(r'local VERSION = "([^"]+)"', text)
        problems = ["%s (%s)" % (n, why) for n, why in NEEDS if n not in text]
        got = accounts(text)
        for acc, vals in want.items():
            if got.get(acc) != vals:
                problems.append("account %s: script has %s, tab has %s" % (acc, got.get(acc), vals))
        hb = re.search(r'wr\("cyber_farm_hb\.json", \{(.*?)\n\s*\}\)', text, re.S)
        if not hb:
            problems.append("heartbeat table not found")
        else:
            for k in HB_KEYS:
                if not re.search(r'\b%s\s*=' % k, hb.group(1)):
                    problems.append("heartbeat has no '%s'" % k)
        print("  %-8s %-34s version %s" % ("PROBLEM" if problems else "ok", label, ver.group(1) if ver else "?"))
        for p in problems:
            print("            -", p)
        bad += 1 if problems else 0
    print("all scripts keep the contract" if bad == 0 else "%d script(s) differ from what the tab expects" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
