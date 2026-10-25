#!/usr/bin/env bash
# Install the temporal-designer Claude skill.
#
# Usage:
#   ./install.sh                 # install to ~/.claude/skills (all projects)
#   ./install.sh --project [DIR] # install to DIR/.claude/skills (default: current dir)
#   ./install.sh --uninstall [--project [DIR]]
#
# Remote (no clone needed):
#   curl -fsSL https://raw.githubusercontent.com/lmquanacs/temporal-design-pattern/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/lmquanacs/temporal-design-pattern/main/install.sh | bash -s -- --project
set -euo pipefail

SKILL_NAME="temporal-designer"
REPO="lmquanacs/temporal-design-pattern"
REF="${TEMPORAL_DESIGNER_REF:-main}"

target_root="${HOME}/.claude/skills"
action="install"

usage() { sed -n '2,12p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      if [[ $# -gt 1 && "$2" != --* ]]; then target_root="$2/.claude/skills"; shift; else target_root="$PWD/.claude/skills"; fi
      ;;
    --uninstall) action="uninstall" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

dest="${target_root}/${SKILL_NAME}"

if [[ "$action" == "uninstall" ]]; then
  if [[ -d "$dest" ]]; then rm -rf "$dest"; echo "Removed ${dest}"; else echo "Not installed at ${dest}"; fi
  exit 0
fi

# Find the skill source: a local checkout next to this script, otherwise download from GitHub.
script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

tmp=""
cleanup() { if [[ -n "$tmp" ]]; then rm -rf "$tmp"; fi; }
trap cleanup EXIT

if [[ -n "$script_dir" && -f "${script_dir}/skills/${SKILL_NAME}/SKILL.md" ]]; then
  src="${script_dir}/skills/${SKILL_NAME}"
  echo "Installing from local checkout: ${src}"
else
  command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
  command -v tar >/dev/null || { echo "tar is required" >&2; exit 1; }
  tmp="$(mktemp -d)"
  echo "Downloading ${REPO}@${REF} ..."
  curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/${REF}" | tar -xz -C "$tmp"
  src="$(find "$tmp" -type d -path "*/skills/${SKILL_NAME}" | head -n 1)"
  [[ -n "$src" && -f "${src}/SKILL.md" ]] || { echo "Skill not found in downloaded archive" >&2; exit 1; }
fi

mkdir -p "$target_root"
if [[ -d "$dest" ]]; then
  # Back up outside skills/ so the old copy is not loaded as a duplicate skill.
  backup_dir="$(dirname "$target_root")/skill-backups"
  backup="${backup_dir}/${SKILL_NAME}.$(date +%Y%m%d%H%M%S)"
  mkdir -p "$backup_dir"
  mv "$dest" "$backup"
  echo "Existing install moved to ${backup}"
fi
cp -R "$src" "$dest"

echo "Installed ${SKILL_NAME} to ${dest}"
echo "Files:"
(cd "$dest" && find . -type f | sort | sed 's/^\.\//  /')
echo "Restart Claude Code (or start a new session) to pick up the skill."
