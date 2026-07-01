#!/bin/zsh
set -euo pipefail
# Cut a Pocket Connect release from your Mac:
#   1. bump CFBundleShortVersionString (+ CFBundleVersion) in Info.plist
#   2. build the .dmg locally (sanity check)
#   3. commit the version bump, tag v<ver>, and push the tag
# The pushed tag triggers .github/workflows/release.yml which builds + uploads
# the .dmg as a GitHub Release asset.
#
# Usage:
#   ./packaging/cut_release.sh 0.2.0     # explicit version
#   ./packaging/cut_release.sh patch     # bump patch (0.1.0 -> 0.1.1)
#   ./packaging/cut_release.sh minor     # bump minor (0.1.0 -> 0.2.0)
#   ./packaging/cut_release.sh major     # bump major (0.1.0 -> 1.0.0)
#
# Env:
#   NO_PUSH=1   build + commit + tag but do not push (dry run for the remote step)

cd "$(dirname "$0")/.."   # mac-app/
PLIST="packaging/Info.plist"

cur=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
arg="${1:-patch}"

bump() {  # $1=current  $2=part
  local part="$2"   # save before `set --` clobbers $2
  local IFS=.; set -- ${=1}; local maj=$1 min=$2 pat=$3  # ${=1}: zsh needs this to word-split
  case "$part" in
    major) echo "$((maj+1)).0.0" ;;
    minor) echo "$maj.$((min+1)).0" ;;
    patch) echo "$maj.$min.$((pat+1))" ;;
  esac
}

case "$arg" in
  major|minor|patch) new=$(bump "$cur" "$arg") ;;
  [0-9]*.[0-9]*.[0-9]*) new="$arg" ;;
  *) echo "✗ 版本參數無效:$arg(用 major/minor/patch 或 x.y.z)" >&2; exit 1 ;;
esac

echo "▸ 版本 $cur → $new"

# Fail early on a dirty tree so we don't tag a mix of unrelated changes.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ working tree 不乾淨,請先 commit/stash 再出版本。" >&2
  git status --short >&2
  exit 1
fi

# Bump both the marketing version and the build number.
buildnum=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST" 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $new" "$PLIST"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $((buildnum+1))" "$PLIST"

echo "▸ 本機 build 驗證"
./packaging/build_dmg.sh >/dev/null
echo "  ✓ build/PocketConnect-$new.dmg"

git add "$PLIST"
git commit -m "release: v$new"
git tag "v$new"

if [[ "${NO_PUSH:-0}" == "1" ]]; then
  echo "▸ NO_PUSH=1 — 已 commit + tag,未推送。手動推:git push && git push origin v$new"
else
  git push
  git push origin "v$new"
  echo "✓ 已推送 tag v$new — GitHub Actions 會 build 並上傳 .dmg 到 Release。"
fi
