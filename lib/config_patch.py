#!/usr/bin/env python3
"""Adds/removes agent-edits entries in agent hook files and tmux.conf.

  config_patch.py hooks-add    FILE MATCHER COMMAND
  config_patch.py hooks-remove FILE
  config_patch.py tmux-add     FILE BLOCK_TEXT
  config_patch.py tmux-remove  FILE

Entries are identified by the marker "agent-edits-log" (hooks) or by the
">>> agent-edits >>>" comment block (tmux), so other hooks and settings are
never touched. Every command is idempotent and prints what it did.
"""
import json
import os
import sys

HOOK_MARKER = "agent-edits-log"
EVENT = "PostToolUse"
TMUX_BEGIN = "# >>> agent-edits >>>"
TMUX_END = "# <<< agent-edits <<<"


def load_json(path):
    if not os.path.exists(path):
        return {}, True
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    return (json.loads(text) if text.strip() else {}), text.endswith("\n") or not text


def save_json(path, data, newline):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".agent-edits.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        if newline:
            fh.write("\n")
    os.replace(tmp, path)


def is_ours(group):
    return any(HOOK_MARKER in h.get("command", "") for h in group.get("hooks", []))


def hooks_add(path, matcher, command):
    data, newline = load_json(path)
    groups = data.setdefault("hooks", {}).setdefault(EVENT, [])
    if any(is_ours(g) for g in groups):
        print(f"  hook already present in {path}")
        return
    groups.append({
        "matcher": matcher,
        "hooks": [{"type": "command", "command": command, "timeout": 5}],
    })
    save_json(path, data, newline)
    print(f"  added {EVENT} hook to {path}")


def hooks_remove(path):
    if not os.path.exists(path):
        return
    data, newline = load_json(path)
    hooks = data.get("hooks", {})
    groups = hooks.get(EVENT, [])
    kept = [g for g in groups if not is_ours(g)]
    if len(kept) == len(groups):
        print(f"  no agent-edits hook in {path}")
        return
    if kept:
        hooks[EVENT] = kept
    else:
        hooks.pop(EVENT, None)
    save_json(path, data, newline)
    print(f"  removed {EVENT} hook from {path}")


def strip_block(text):
    out, inside = [], False
    for line in text.splitlines(keepends=True):
        if line.strip() == TMUX_BEGIN:
            inside = True
        elif line.strip() == TMUX_END and inside:
            inside = False
        elif not inside:
            out.append(line)
    return "".join(out)


def tmux_add(path, block):
    text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
    # Drop any previous block, then append the current one at the end.
    base = strip_block(text).rstrip("\n")
    new = (base + "\n\n" if base else "") + f"{TMUX_BEGIN}\n{block.rstrip()}\n{TMUX_END}\n"
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(new)
    print(f"  wrote key binding block to {path}")


def tmux_remove(path):
    if not os.path.exists(path):
        return
    text = open(path, encoding="utf-8").read()
    base = strip_block(text)
    if base == text:
        print(f"  no agent-edits block in {path}")
        return
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(base.rstrip("\n") + "\n")
    print(f"  removed key binding block from {path}")


def main(argv):
    cmd, args = argv[1], argv[2:]
    {
        "hooks-add": hooks_add,
        "hooks-remove": hooks_remove,
        "tmux-add": tmux_add,
        "tmux-remove": tmux_remove,
    }[cmd](*args)


if __name__ == "__main__":
    main(sys.argv)
