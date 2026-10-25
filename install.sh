#!/bin/bash
# Builds Taskboard.app, puts it into Applications, opens it and connects taskboard-mcp to the wingform Claude profile.
set -euo pipefail
cd "$(dirname "$0")"

scripts/build-app.sh

TARGET=/Applications
[ -w "$TARGET" ] || TARGET="$HOME/Applications"
mkdir -p "$TARGET"
pkill -x Taskboard 2>/dev/null || true
sleep 1
rm -rf "$TARGET/Taskboard.app"
cp -R dist/Taskboard.app "$TARGET/"
open "$TARGET/Taskboard.app"

PROFILE="${CLAUDE_PROFILE_DIR:-$HOME/.claude-wingform}"
MCP="$TARGET/Taskboard.app/Contents/MacOS/taskboard-mcp"
if command -v claude >/dev/null; then
  CLAUDE_CONFIG_DIR="$PROFILE" claude mcp remove --scope user taskboard >/dev/null 2>&1 || true
  CLAUDE_CONFIG_DIR="$PROFILE" claude mcp add --scope user taskboard "$MCP"
fi
# Skill: a symlink to the source in the repo, so edits are picked up without reinstalling.
mkdir -p "$PROFILE/skills"
ln -sfn "$PWD/skills/taskboard" "$PROFILE/skills/taskboard"
echo "Installed to $TARGET/Taskboard.app; MCP taskboard and skill → $PROFILE"
