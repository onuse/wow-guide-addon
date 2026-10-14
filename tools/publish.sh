#!/bin/bash
# Publish one Guide release to the share as its own folder,
#   \\192.168.1.81\SharePiFast\WoWfiles\Guide-<version>\Guide
# as a zip on the downloads page (public, through the monitor's Funnel front):
#   https://grizzlyhills.tail2c599a.ts.net:8443/downloads/addons/Guide-<version>.zip
# and never touch either again. A new version is a new path: Windows has nothing
# cached for it, so no stale listings and no "0x80070057 Felaktig parameter"
# (2026-10-11, when replacing the one Guide folder under an open Explorer).
# Every version stays on the share as a list (Jonas: "it looks kind of nice").
#
#   tools/publish.sh            the version in Guide/Guide.lua, from the working tree
#   tools/publish.sh v0.4.1     an older one, from its git tag
set -euo pipefail
SHARE=/mnt/wow-data2/Share/WoWfiles
cd "$(dirname "$0")/.."
if [ $# -ge 1 ]; then
  tag=$1; ver=${tag#v}
  src=$(mktemp -d); git archive "$tag" Guide | tar -x -C "$src"; src=$src/Guide
else
  ver=$(sed -n 's/^local VERSION = "\(.*\)"/\1/p' Guide/Guide.lua)
  toc=$(sed -n 's/^## Version: //p' Guide/Guide.toc)
  [ "$ver" = "$toc" ] || { echo "Guide.lua says $ver, Guide.toc says $toc - fix one"; exit 1; }
  [ -z "$(git status --porcelain Guide)" ] || { echo "Guide/ has uncommitted changes - commit and tag first"; exit 1; }
  src=Guide
fi
dest=$SHARE/Guide-$ver
[ -e "$dest" ] && { echo "$dest exists - a published version is never changed; bump the version"; exit 1; }
mkdir -p "$dest/Guide"
cp "$src"/* "$dest/Guide/"
sudo -n chown -R nobody:nogroup "$dest"
sudo -n chmod -R a+rwX "$dest"
zip=/mnt/wow-data2/downloads/addons/Guide-$ver.zip
[ -e "$zip" ] || (cd "$dest" && zip -qr "$zip" Guide)
echo "published $dest"
echo "published https://grizzlyhills.tail2c599a.ts.net:8443/downloads/addons/Guide-$ver.zip"
# The public copy: a GitHub release per version, with the same zip. No port
# to mistype (Lind and Emil could not reach the :8443 address, 2026-10-14).
if gh release view "v$ver" >/dev/null 2>&1; then
  echo "GitHub release v$ver already exists"
else
  git push -q origin master "v$ver"
  gh release create "v$ver" "$zip" --title "Guide $ver" --notes "Unzip into World of Warcraft/Interface/AddOns/." >/dev/null
  echo "published https://github.com/onuse/wow-guide-addon/releases/tag/v$ver"
fi
