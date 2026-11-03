#!/bin/zsh
set -euo pipefail
# Cut a Pocket Connect release from your Mac:
#   1. bump CFBundleShortVersionString (+ CFBundleVersion) in Info.plist
#   2. build the .dmg locally (sanity check)
#   3. commit the version bump, tag v<ver>, and push the tag
# The pushed tag triggers .github/workflows/release-macos.yml which signs,
# notarizes, smoke-tests and uploads the .dmg + .sha256 as Release assets.
# (2026-11-03 起恢復 CI 發佈;空包根因已修 —— 見該 workflow 檔頭的翻案紀錄。)
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
echo "  ✓ build/dist/Pocket-$new.dmg"

git add "$PLIST"
git commit -m "release: v$new"
git tag "v$new"

if [[ "${NO_PUSH:-0}" == "1" ]]; then
  echo "▸ NO_PUSH=1 — 已 commit + tag,未推送。手動推:git push && git push origin v$new"
else
  git push
  git push origin "v$new"
  echo "✓ 已推送 tag v$new。"
fi

# ⚠️ 本段歷史(留著,因為兩個方向的錯都發生過):
#    · 2026-10-21 之前這裡說「CI 會上傳資產」—— 當時是錯的(2026-10-05 起
#      CI 永不碰 release 資產:v0.3/v0.4 的「本機正貨 vs CI 空包」賽跑,
#      CI 抓不到私有 bridge repo,建出的 DMG 沒 bridge,乾淨 Mac 是死路)。
#    · 2026-11-03 起又是對的:release-macos.yml 用 deploy key checkout
#      bridge、build_dmg.sh 擋無 bridge 公證版、smoke_dmg.sh 行為探針驗
#      「app 找得到內附 bridge」,空包三道都過不了。根因修了,不是繞開。
#      secrets 清單與首次驗證流程見 docs/CI_RELEASE.md。
cat <<EOT

▸ tag 已推送 —— CI(release-macos.yml)接手:簽名 + 公證 + 煙霧測試 + 上傳資產。

    盯 run:    gh run watch --repo cashtsai/pocket-connect
    發佈後驗:  ./packaging/verify_release.sh "v$new"

  驗「使用者真的會下載到的那顆」不是形式:線上的 v0.5.1 實測 stapler validate
  **沒有票據** —— 公證做了,但上傳的那顆不是 staple 過的那顆。有網路的人不會
  遇到,所以本機怎麼測都測不出來。驗的對象必須是下載回來的那一顆。

▸ CI 壞掉時的本機後備(⚠️ 跟 CI **不要**同時跑 —— 兩邊都會上傳,就是當年
  v0.3/v0.4 的賽跑。先到 Actions 取消那個 run 再動手):

    NOTARIZE=1 BUNDLE_BRIDGE=1 ./packaging/build_dmg.sh
    gh release create "v$new" "build/dist/Pocket-$new.dmg" \
        "build/dist/Pocket-$new.dmg.sha256" --title "v$new" --generate-notes
    ./packaging/verify_release.sh "v$new"
EOT
