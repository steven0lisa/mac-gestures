#!/bin/bash
# bump-version.sh — 升级版本号（VERSION / package.json / project.yml 三处同步）
# 通用模板：放在仓库 scripts/ 下即可用，缺哪个文件自动跳过哪处同步。
# Usage: ./scripts/bump-version.sh [major|minor|patch]
set -e

TYPE=${1:-patch}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$PROJECT_DIR/VERSION"

if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: VERSION file not found"
    exit 1
fi

CURRENT=$(tr -d '[:space:]' < "$VERSION_FILE")
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

case $TYPE in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
    *) echo "Usage: $0 [major|minor|patch]"; exit 1 ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"
echo "$NEW_VERSION" > "$VERSION_FILE"

# 同步 package.json 顶层 version。
# 必须用 2 空格缩进锚定：否则会把 releaseHistory 数组里历史条目的同版本号一并改掉
if [ -f "$PROJECT_DIR/package.json" ]; then
    sed -i '' "s/^  \"version\": \"$CURRENT\"/  \"version\": \"$NEW_VERSION\"/" "$PROJECT_DIR/package.json"
fi

# 同步 project.yml（XcodeGen 工程定义的 MARKETING_VERSION）
if [ -f "$PROJECT_DIR/project.yml" ]; then
    sed -i '' "s/MARKETING_VERSION: \"$CURRENT\"/MARKETING_VERSION: \"$NEW_VERSION\"/" "$PROJECT_DIR/project.yml"
fi

echo "Version bumped: $CURRENT -> $NEW_VERSION"
echo ""
echo "Next steps:"
echo "  1. 在 package.json 的 releaseHistory 顶部加新版本条目（CI 会作为 Release Notes）"
echo "  2. git add <明确文件清单> && git commit -m 'chore: bump version to $NEW_VERSION'"
echo "  3. git tag v$NEW_VERSION && git push origin main --tags"
