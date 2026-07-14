#!/bin/bash
set -e

ROOT_DIR="$PWD"
SRC_DIR="$ROOT_DIR/src"

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
CRAFTOS_BASE="/Users/bucket/Library/Application Support/CraftOS-PC/computer"
NEET_BASE="/Users/bucket/Library/Application Support/ModrinthApp/profiles/Neet/saves/New World/neetcomputers"

# ----------------------------------------------------------------------------
# Argument parsing
#   --target cc|neet   platform to deploy for (default: cc)
#   -c, --computer ID  computer id (CraftOS computer dir / NEET disk folder)
#                      default 0 for cc; required for neet
#   --cli              (cc only) launch CraftOS-PC in ncurses CLI mode after deploy
#   --headless         (cc only) launch CraftOS-PC in headless (stdout-only) mode after deploy
# ----------------------------------------------------------------------------
TARGET="cc"
COMPUTER_ID=""
RUN_MODE=""

usage() {
  echo "Usage: ./deploy.sh [--target cc|neet] [-c <computerId>] [--cli|--headless]"
  echo "  --target cc            deploy to CraftOS-PC (default)"
  echo "  --target neet -c <id>  deploy into neetcomputers/<id>/system/"
  echo "  -c, --computer <id>    computer id (cc: computer dir, default 0; neet: disk folder, required)"
  echo "  --cli                  cc only: launch CraftOS-PC in ncurses CLI mode after deploy"
  echo "  --headless             cc only: launch CraftOS-PC in headless (stdout-only) mode after deploy"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)        TARGET="$2"; shift 2 ;;
    -c|--computer)   COMPUTER_ID="$2"; shift 2 ;;
    --cli)           RUN_MODE="cli"; shift ;;
    --headless)      RUN_MODE="headless"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "Unknown argument: $1"; echo; usage; exit 1 ;;
  esac
done

if [[ "$TARGET" != "cc" && "$TARGET" != "neet" ]]; then
  echo "Error: --target must be 'cc' or 'neet' (got '$TARGET')"; exit 1
fi

if [[ -z "$COMPUTER_ID" ]]; then
  if [[ "$TARGET" == "cc" ]]; then
    COMPUTER_ID=0
  else
    echo "Error: --target neet requires -c <computerId> (the disk folder under neetcomputers/)"; exit 1
  fi
fi

# ----------------------------------------------------------------------------
# Deploy (no build step: src/ is plain Lua, copied as-is)
# ----------------------------------------------------------------------------
if [[ "$TARGET" == "cc" ]]; then
  CRAFTOS_DIR="$CRAFTOS_BASE/$COMPUTER_ID"
  echo "Deploying to CraftOS-PC (computer $COMPUTER_ID)..."
  mkdir -p "$CRAFTOS_DIR"
  rm -rf "${CRAFTOS_DIR:?}"/*
  cp -R "$SRC_DIR/." "$CRAFTOS_DIR/"
  echo "Deploy complete!"

  if [[ -n "$RUN_MODE" ]]; then
    if [[ "$RUN_MODE" == "cli" ]]; then
      MODE_FLAG="--cli"
      echo "Launching CraftOS-PC (CLI mode)..."
    else
      MODE_FLAG="--headless"
      echo "Launching CraftOS-PC (headless mode)..."
    fi

    CRAFTOS_APP="/Applications/CraftOS-PC.app/Contents/MacOS/craftos"
    if command -v craftos &> /dev/null; then
      craftos "$MODE_FLAG" --id "$COMPUTER_ID"
    elif [ -f "$CRAFTOS_APP" ]; then
      "$CRAFTOS_APP" "$MODE_FLAG" --id "$COMPUTER_ID"
    else
      echo "Error: Could not find 'craftos' executable."
      echo "Please add it to your PATH or ensure it is in /Applications."
    fi
  fi

elif [[ "$TARGET" == "neet" ]]; then
  NEET_DISK="$NEET_BASE/$COMPUTER_ID"
  if [ ! -f "$NEET_DISK/build.json" ]; then
    echo "Error: NEET disk '$COMPUTER_ID' not found (expected: $NEET_DISK/build.json)."
    echo "       Create the computer in-game first, or pass a valid -c id."
    exit 1
  fi

  SYSTEM_PART="$NEET_DISK/system"
  echo "Deploying to NEET disk $COMPUTER_ID -> system/ partition..."
  echo " (only system/ is touched; overlay/, bios/, user/, build.json are left alone)"
  rm -rf "$SYSTEM_PART"
  mkdir -p "$SYSTEM_PART"
  cp -R "$SRC_DIR/." "$SYSTEM_PART/"
  echo "Deploy complete! Reboot the computer in-game to load."
fi
