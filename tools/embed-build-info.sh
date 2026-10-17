#!/bin/sh
# Xcode build phase (HRV target): writes BuildInfo.plist into the app bundle with the git
# commit, branch, uncommitted-changes flag and build time. The Strap tab shows it.
#
# The HRV target sets ENABLE_USER_SCRIPT_SANDBOXING = NO for this script: `git status` reads
# .git (outside SRCROOT in a worktree) and every tracked file, which can't be declared as inputs.
#
# Never fails the build: outside a git checkout the values are "unknown".

out="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/BuildInfo.plist"
g() { git -C "$SRCROOT" "$@"; }

commit=$(g rev-parse --short=7 HEAD 2>/dev/null) || commit=unknown
branch=$(g rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=unknown
# CI checks out a detached HEAD; GitHub Actions names the branch in the environment.
if [ "$branch" = HEAD ]; then
    branch=${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-HEAD}}
fi
dirty=false
if [ "$commit" != unknown ] && [ -n "$(g --no-optional-locks status --porcelain 2>/dev/null)" ]; then
    dirty=true
fi

mkdir -p "$(dirname "$out")"
plutil -create xml1 "$out"
plutil -insert GitCommit -string "$commit" "$out"
plutil -insert GitBranch -string "$branch" "$out"
plutil -insert GitDirty -bool "$dirty" "$out"
plutil -insert BuildTime -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$out"
echo "Build info: $commit $branch dirty=$dirty"
