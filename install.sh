#!/usr/bin/env bash
# Installs agent-edits: symlinks the scripts, registers the agent hooks and
# adds a tmux key binding. Safe to run again (idempotent).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN_DIR="${AGENT_EDITS_BIN_DIR:-$HOME/.local/bin}"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-edits"
CLAUDE_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
CODEX_HOOKS="${CODEX_HOME:-$HOME/.codex}/hooks.json"
PATCH=(python3 "$REPO/lib/config_patch.py")

# Tools whose calls the hook logs, per agent. Grok reads Claude's settings and
# maps Claude's tool names to its own.
CLAUDE_MATCHER="Edit|Write|MultiEdit|NotebookEdit"
CODEX_MATCHER="apply_patch|Edit|Write"

key="e"
do_claude=1 do_codex=1 do_tmux=1 codex_notice=0

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  --key KEY      tmux key, pressed after the prefix (default: e)
  --no-claude    don't add the hook to $CLAUDE_SETTINGS (also used by Grok)
  --no-codex     don't add the hook to $CODEX_HOOKS
  --no-tmux      don't add the tmux key binding
  -h, --help     show this help
EOF
}

while (($#)); do
  case "$1" in
    --key) key="${2:?--key needs a value}"; shift ;;
    --no-claude) do_claude=0 ;;
    --no-codex) do_codex=0 ;;
    --no-tmux) do_tmux=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# patch FILE CMD...: run CMD (which edits FILE) and keep a timestamped backup
# of FILE only when CMD actually changed it.
patch() {
  local file="$1" tmp=""
  shift
  if [[ -f "$file" ]]; then
    tmp="$(mktemp)"
    cp -p "$file" "$tmp"
  fi
  "$@"
  if [[ -n "$tmp" ]]; then
    if cmp -s "$tmp" "$file"; then
      rm -f "$tmp"
    else
      local dest="$file.bak-agent-edits-$(date +%Y%m%d-%H%M%S)"
      mv "$tmp" "$dest"
      echo "  backup: $dest"
    fi
  fi
}

say "Checking dependencies"
for cmd in python3 nvim git; do
  command -v "$cmd" >/dev/null || die "'$cmd' not found in PATH"
done
nvim --headless -c 'if !has("nvim-0.9") | cquit | endif' -c 'qa!' 2>/dev/null \
  || die "Neovim 0.9 or newer is required"
if ((do_tmux)); then
  command -v tmux >/dev/null || die "'tmux' not found (use --no-tmux to skip)"
  tmux_ver="$(tmux -V | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  awk -v v="$tmux_ver" 'BEGIN { exit !(v + 0 >= 3.3) }' \
    || die "tmux 3.3 or newer is required for display-popup -T (found $tmux_ver)"
fi

say "Linking files"
mkdir -p "$BIN_DIR" "$CONF_DIR"
for f in agent-edits-log agent-edits-view agent-edits-popup; do
  chmod +x "$REPO/bin/$f"
  ln -sfn "$REPO/bin/$f" "$BIN_DIR/$f"
  echo "  $BIN_DIR/$f -> $REPO/bin/$f"
done
ln -sfn "$REPO/nvim/viewer.lua" "$CONF_DIR/viewer.lua"
echo "  $CONF_DIR/viewer.lua -> $REPO/nvim/viewer.lua"
ln -sfn "$REPO/tmux/inner.conf" "$CONF_DIR/inner.conf"
echo "  $CONF_DIR/inner.conf -> $REPO/tmux/inner.conf"

if ((do_claude)); then
  say "Claude Code / Grok hook"
  patch "$CLAUDE_SETTINGS" "${PATCH[@]}" hooks-add "$CLAUDE_SETTINGS" PostToolUse \
    "$CLAUDE_MATCHER" "$BIN_DIR/agent-edits-log Claude"
fi

if ((do_codex)); then
  say "Codex hook"
  if [[ -d "$(dirname "$CODEX_HOOKS")" ]]; then
    patch "$CODEX_HOOKS" "${PATCH[@]}" hooks-add "$CODEX_HOOKS" PostToolUse \
      "$CODEX_MATCHER" "$BIN_DIR/agent-edits-log Codex"
    codex_notice=1
  else
    echo "  Codex not found, skipping"
  fi
fi

if ((do_tmux)); then
  say "tmux key binding (prefix + $key)"
  tmux_conf="${XDG_CONFIG_HOME:-$HOME/.config}/tmux/tmux.conf"
  [[ -f "$tmux_conf" || ! -f "$HOME/.tmux.conf" ]] || tmux_conf="$HOME/.tmux.conf"
  patch "$tmux_conf" "${PATCH[@]}" tmux-add "$tmux_conf" \
    "bind $key run-shell -b \"$BIN_DIR/agent-edits-popup --open $key #{q:client_name} #{q:socket_path} #{q:pane_id} #{q:pane_current_path}\""
  printf '%s\n' "$key" > "$CONF_DIR/tmux-key"
  if tmux info >/dev/null 2>&1; then
    tmux source-file "$tmux_conf" && echo "  reloaded running tmux server"
  fi
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not in your PATH (the tmux binding still works)" ;;
esac

say "Done. Restart running agents so they load the new hook."
if ((codex_notice)); then
  warn "Codex only runs hooks you trust. Open Codex, run /hooks and trust the
         agent-edits-log hooks, otherwise Codex edits are not recorded.
         Codex asks again whenever install.sh changes the hook."
fi
((do_tmux)) && echo "    Open the viewer with: <tmux prefix> $key"
exit 0
