#!/bin/bash
# Dual-package HAR staging (PR #82 review 意见②③).
#
# `@ohos-rs/ability` is split into the core bridge-contract package and
# `@ohos-rs/ability-support`; each publishes as its own har. `ohrs artifact`
# cannot pack a pure-ArkTS tree (it requires a cargo package context), so this
# follows the tauri-side pack.bat recipe verified end-to-end there: stage the
# package metadata + ets (+resources) under a `package/` dir, then `tar -czf`
# — a .har is a tar.gz whose top-level `package/` layout ohpm installs.
#
# Outputs: dist/ability.har, dist/ability_support.har.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ROOT=$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)
DIST="$ROOT/dist"

rm -rf "$DIST"
mkdir -p "$DIST"

# stage <har-file> <source-dir> <metadata-file>...
# Stages <source-dir>'s metadata files + src/main/ets (+ resources when the
# package has them) into dist/<har-file>/package.
stage() {
  local har="$1" src="$2"
  shift 2
  local staging="$DIST/$har/package"
  mkdir -p "$staging/src/main"
  local f
  for f in "$@"; do
    cp "$ROOT/$src/$f" "$staging/$f"
  done
  cp -r "$ROOT/$src/src/main/ets" "$staging/src/main/ets"
  if [ -d "$ROOT/$src/src/main/resources" ]; then
    cp -r "$ROOT/$src/src/main/resources" "$staging/src/main/resources"
  fi
}

stage ability_support ability_support \
  oh-package.json5 index.ets build-profile.json5 BuildProfile.ets hvigorfile.ts
tar -czf "$DIST/ability_support.har" -C "$DIST/ability_support" package

stage ability native_ability \
  oh-package.json5 index.ets build-profile.json5 BuildProfile.ets hvigorfile.ts \
  obfuscation-rules.txt consumer-rules.txt
# Registry-shaped dependency: the core har declares a semver range on the
# support package, not the workspace-local file: path (ohpm workspace mode
# resolves that at publish time; the staged har must be standalone).
SUPPORT_VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/ability_support/oh-package.json5" | head -n 1)
sed -i "s|\"@ohos-rs/ability-support\": \"file:../ability_support\"|\"@ohos-rs/ability-support\": \"^$SUPPORT_VERSION\"|" \
  "$DIST/ability/package/oh-package.json5"
tar -czf "$DIST/ability.har" -C "$DIST/ability" package

# Structural self-check: every file in each archive must map back to a real
# file in its source tree (oh-package.json5 excepted — the core one is
# rewritten above).
fail=0
check() {
  local har="$1" src="$2"
  local mapped
  mapped=$(tar -tf "$DIST/$har.har" | sed -e '/\/$/d' -e 's|^package/||')
  local rel
  while IFS= read -r rel; do
    [ "$rel" = "oh-package.json5" ] && continue
    if [ ! -f "$ROOT/$src/$rel" ]; then
      echo "[pack] $har.har: '$rel' has no source counterpart in $src/" >&2
      fail=1
    fi
  done <<< "$mapped"
  echo "[pack] $har.har: $(wc -l <<< "$mapped") files mapped back to $src/"
}
check ability_support ability_support
check ability native_ability

exit "$fail"
