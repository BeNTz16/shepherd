#!/usr/bin/env bash
set -euo pipefail
# Local install or clone to a persistent checkout before installing.
repo="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
source_repo=$repo
if [[ -n "${SHEPHERD_REPO_URL:-}" ]]; then
  repo="${SHEPHERD_CHECKOUT:-${XDG_DATA_HOME:-$HOME/.local/share}/shepherd}"
  if [[ ! -d "$repo" ]]; then
    mkdir -p -- "$(dirname -- "$repo")"
    git clone -- "$SHEPHERD_REPO_URL" "$repo"
  elif [[ ! -d "$repo/.git" || ! -f "$repo/skills/shepherd/SKILL.md" ]]; then
    echo "Refusing unrelated checkout: $repo" >&2; exit 2
  fi
fi
[[ -f "$repo/skills/shepherd/SKILL.md" && -f "$repo/config/shepherd.env" ]] || { echo 'Incomplete shepherd checkout' >&2; exit 2; }
fail() { echo "Refusing unsafe installation: $*" >&2; exit 2; }
no_symlinks() {
  local path=$1
  while [[ "$path" != / && "$path" != . ]]; do
    [[ ! -L "$path" ]] || fail "symlink component: $path"
    path="$(dirname -- "$path")"
  done
}
repo="$(realpath -e -- "$repo")"
target="${SHEPHERD_INSTALL_DIR:-$HOME/.claude/skills/shepherd}"
[[ "$target" == /* ]] || target="$PWD/$target"
mode=${SHEPHERD_INSTALL_MODE:-symlink}
[[ "$mode" == symlink || "$mode" == copy ]] || fail 'SHEPHERD_INSTALL_MODE must be symlink or copy'
# Check the original spelling too: a symlink followed by /.. is unsafe.
no_symlinks "$(dirname -- "$target")"
target="$(realpath -ms -- "$target")"
for source in "$source_repo" "$repo"; do
  [[ "$target" != "$source" && "$target" != "$source/"* && "$source" != "${target%/}/"* ]] || fail "target overlaps source: $target"
done
for path in "$repo/skills/shepherd/SKILL.md" "$repo/skills/shepherd/scripts/shepherd-run.sh" "$repo/config/shepherd.env"; do
  no_symlinks "$path"
  [[ -f "$path" ]] || fail "source is not a regular file: $path"
done
# The exact link created by this installer is the only directory-link exception.
if [[ -L "$target" ]]; then
  [[ "$mode" == symlink && "$(readlink -- "$target")" == "$repo/skills/shepherd" ]] || fail "symlink target: $target"
fi
for tree in "$repo/skills/shepherd" "$target"; do
  if [[ -d "$tree" && ! -L "$tree" ]]; then
    links="$(find "$tree" -type l -print -quit)" || fail "cannot inspect tree: $tree"
    [[ -z "$links" ]] || fail "symlink in installation tree: $tree"
  fi
done
remove_file() {
  local path=$1 resolved
  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  [[ -f "$path" ]] || fail "not a regular file: $path"
  resolved="$(realpath -e -- "$path")"
  [[ "$resolved" == "$target" || "$resolved" == "$target/"* ]] || fail "file escapes target: $path"
  rm -f -- "$path"
}
mkdir -p -- "$(dirname -- "$target")"
case "$mode" in
  symlink)
    [[ ! -d "$target" || -L "$target" ]] || { echo "Refusing to replace directory: $target" >&2; exit 2; }
    if [[ ! -L "$target" ]]; then
      remove_file "$target"
      ln -s -- "$repo/skills/shepherd" "$target"
    fi
    ;;
  copy)
    [[ ! -d "$target" || -L "$target" || -f "$target/SKILL.md" ]] || { echo "Refusing unrelated directory: $target" >&2; exit 2; }
    if [[ -f "$target" ]]; then remove_file "$target"; fi
    mkdir -p -- "$target/scripts" "$target/config"
    remove_file "$target/SKILL.md"
    remove_file "$target/scripts/shepherd-run.sh"
    remove_file "$target/config/shepherd.env"
    cp -- "$repo/skills/shepherd/SKILL.md" "$target/SKILL.md"
    cp -- "$repo/skills/shepherd/scripts/shepherd-run.sh" "$target/scripts/shepherd-run.sh"
    cp -- "$repo/config/shepherd.env" "$target/config/shepherd.env"
    ;;
  *) echo 'SHEPHERD_INSTALL_MODE must be symlink or copy' >&2; exit 2;;
esac
chmod +x -- "$target/scripts/shepherd-run.sh"
echo "Installed shepherd: $target"
