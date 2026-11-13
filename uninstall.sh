#!/usr/bin/env bash
# Reverts everything install.sh did. Other hooks and settings are left untouched.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_DIR="${AGENT_EDITS_BIN_DIR:-$HOME/.local/bin}"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-edits"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-edits"
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
CODEX_HOOKS="${CODEX_HOME:-$HOME/.codex}/hooks.json"
PATCH=(python3 "$REPO/lib/config_patch.py")

purge=0
case "${1:-}" in
  --purge) purge=1 ;;
  -h|--help)
    echo "Usage: ./uninstall.sh [--purge]   (--purge also deletes the edit log)"
    exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

say "Removing hooks"
"${PATCH[@]}" hooks-remove "$CLAUDE_SETTINGS"
"${PATCH[@]}" hooks-remove "$CODEX_HOOKS"

say "Removing tmux key binding"
key="$(cat "$CONF_DIR/tmux-key" 2>/dev/null || echo e)"
for conf in "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf" "$HOME/.tmux.conf"; do
  "${PATCH[@]}" tmux-remove "$conf"
done
if tmux info >/dev/null 2>&1 \
  && tmux list-keys -T prefix "$key" 2>/dev/null | grep -q agent-edits-; then
  tmux unbind-key -T prefix "$key" && echo "  unbound prefix + $key in running tmux server"
fi
if tmux -L agent-edits kill-server 2>/dev/null; then
  echo "  closed the viewers kept in the background"
fi

say "Removing files"
for f in agent-edits-log agent-edits-view agent-edits-popup; do
  link="$BIN_DIR/$f"
  if [[ -L "$link" && "$(readlink "$link")" == "$REPO/bin/$f" ]]; then
    rm "$link" && echo "  removed $link"
  fi
done
rm -rf "$CONF_DIR" && echo "  removed $CONF_DIR"

if ((purge)); then
  rm -rf "$STATE_DIR" && echo "  removed $STATE_DIR"
else
  echo "  kept edit log in $STATE_DIR (use --purge to delete it)"
fi

say "Done. Backups made by install.sh (*.bak-agent-edits-*) were kept."
