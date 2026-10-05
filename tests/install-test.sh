#!/usr/bin/env bash
# Offline installer checks; never change the real checkout or invoke Codex.
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
repo="$temp/repo"
mkdir -p -- "$repo/skills/shepherd/scripts" "$repo/config"
cp -- "$root/install.sh" "$repo/install.sh"
cp -- "$root/skills/shepherd/SKILL.md" "$repo/skills/shepherd/SKILL.md"
cp -- "$root/skills/shepherd/scripts/shepherd-run.sh" "$repo/skills/shepherd/scripts/shepherd-run.sh"
cp -- "$root/config/shepherd.env" "$repo/config/shepherd.env"
unset SHEPHERD_REPO_URL SHEPHERD_CHECKOUT SHEPHERD_INSTALL_DIR SHEPHERD_INSTALL_MODE
source_files=("$repo/skills/shepherd/SKILL.md" "$repo/skills/shepherd/scripts/shepherd-run.sh" "$repo/config/shepherd.env")
before="$(cksum "${source_files[@]}")"
expect_rejection() {
  local status=0
  bash "$repo/install.sh" > "$temp/output" 2>&1 || status=$?
  [[ "$status" == 2 ]] || { printf 'Expected exit 2, got %s\n' "$status" >&2; exit 1; }
  [[ "$(cksum "${source_files[@]}")" == "$before" ]]
}
for mode in symlink copy; do
  export HOME="$temp/home-$mode" SHEPHERD_INSTALL_MODE=$mode
  target="$HOME/.claude/skills/shepherd"
  chmod 644 -- "$repo/skills/shepherd/scripts/shepherd-run.sh"
  bash "$repo/install.sh" > "$temp/output"
  bash "$repo/install.sh" > "$temp/output"
  [[ -f "$target/SKILL.md" && -x "$target/scripts/shepherd-run.sh" ]]
  cmp -- "$repo/skills/shepherd/SKILL.md" "$target/SKILL.md"
  if [[ "$mode" == symlink ]]; then
    [[ -L "$target" && -x "$repo/skills/shepherd/scripts/shepherd-run.sh" ]]
  else
    [[ ! -L "$target" ]]
    cmp -- "$repo/config/shepherd.env" "$target/config/shepherd.env"
  fi
  status=0
  "$target/scripts/shepherd-run.sh" > "$temp/output" 2>&1 || status=$?
  [[ "$status" == 2 ]]
  grep -Eq '^Usage: shepherd-run.sh ' "$temp/output"
  for unsafe in "$repo" "$repo/skills/shepherd" "$repo/new-skill" "$temp"; do
    export SHEPHERD_INSTALL_DIR=$unsafe
    expect_rejection
  done
  unset SHEPHERD_INSTALL_DIR
done

outside="$temp/outside"
mkdir -p -- "$outside"
for name in SKILL.md shepherd-run.sh shepherd.env sentinel; do
  printf 'DO NOT TOUCH\n' > "$outside/$name"
done
outside_before="$(cksum "$outside/"*)"
for mode in symlink copy; do
  export SHEPHERD_INSTALL_MODE=$mode
  for component in .claude .claude/skills .claude/skills/shepherd .claude/skills/shepherd/scripts .claude/skills/shepherd/config; do
    export HOME="$temp/unsafe-$mode-${component//\//-}"
    target="$HOME/.claude/skills/shepherd"
    link="$HOME/$component"
    mkdir -p -- "$(dirname -- "$link")"
    if [[ "$component" == */scripts || "$component" == */config ]]; then
      cp -- "$repo/skills/shepherd/SKILL.md" "$target/SKILL.md"
    fi
    ln -s -- "$outside" "$link"
    expect_rejection
    [[ "$(cksum "$outside/"*)" == "$outside_before" ]]
    [[ -L "$link" ]]
  done
done
# Reject a symlink before /.., and a leaf link that would overwrite outside data.
export HOME="$temp/dotdot" SHEPHERD_INSTALL_MODE=copy
mkdir -p -- "$HOME"
ln -s -- "$outside" "$HOME/link"
export SHEPHERD_INSTALL_DIR="$HOME/link/../skill"
expect_rejection
unset SHEPHERD_INSTALL_DIR
target="$HOME/.claude/skills/shepherd"
mkdir -p -- "$target/scripts" "$target/config"
cp -- "$repo/skills/shepherd/SKILL.md" "$target/SKILL.md"
ln -s -- "$outside/shepherd-run.sh" "$target/scripts/shepherd-run.sh"
expect_rejection
[[ "$(cksum "$outside/"*)" == "$outside_before" ]]
[[ "$(cksum "${source_files[@]}")" == "$before" ]]
printf 'ALL OK\n'
