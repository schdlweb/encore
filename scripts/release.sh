#!/bin/zsh
# Publishes a new version of Encore: bumps VERSION, builds the shareable zip, commits,
# tags, pushes, and creates a GitHub release with the zip. Running copies of Encore
# offer the update on their next launch (or Encore ▸ Check for Updates…).
#
#   ./scripts/release.sh                 # 1.0.0 → 1.0.1
#   ./scripts/release.sh minor "Notes"   # 1.0.1 → 1.1.0, with release notes
#   ./scripts/release.sh 2.0.0 "Notes"
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
REPO=schdlweb/encore

current=$(cat VERSION)
parts=(${(s:.:)current})
case ${1:-patch} in
  patch) next="${parts[1]}.${parts[2]}.$((parts[3] + 1))" ;;
  minor) next="${parts[1]}.$((parts[2] + 1)).0" ;;
  major) next="$((parts[1] + 1)).0.0" ;;
  *) next=$1 ;;
esac
notes=${2:-"Encore $next"}

if [[ -n $(git status --porcelain -- VERSION) ]]; then echo "VERSION has uncommitted changes" >&2; exit 1; fi
echo "Releasing $current → $next"
echo $next > VERSION
./scripts/package.sh

git add -A
git commit -m "Release $next" -m "$notes"
git tag "v$next"
git push origin HEAD --tags
gh release create "v$next" build.nosync/Encore.zip --repo $REPO --title "Encore $next" --notes "$notes"
echo "Published https://github.com/$REPO/releases/tag/v$next"
