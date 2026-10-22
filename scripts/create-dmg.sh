#!/bin/bash
# create-dmg.sh — 创建带背景图和 Applications 拖拽引导的 DMG（通用模板）
# 卷名/app 名从参数自动派生，无需改代码；想换背景图改内嵌 python 段。
# Usage: ./scripts/create-dmg.sh <app_path> <version> <output_path> [volume_name]
set -e

APP_PATH="${1:?Usage: create-dmg.sh <app_path> <version> <output_path> [volume_name]}"
VERSION="${2:?}"
OUTPUT_PATH="${3:?}"
APP_NAME="$(basename "${APP_PATH}")"
VOLUME_NAME="${4:-$(basename "${APP_PATH}" .app)}"
STAGING_DIR=$(mktemp -d)
DMG_TEMP="${STAGING_DIR}/temp.dmg"
MOUNT_POINT=""

cleanup() {
    [ -n "${MOUNT_POINT}" ] && hdiutil detach "${MOUNT_POINT}" -quiet 2>/dev/null || true
    rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

echo "[create-dmg] Version: ${VERSION}"

# 1. 组装暂存目录（app + Applications 链接 + 背景目录）
echo "[create-dmg] Staging contents..."
mkdir -p "${STAGING_DIR}/${VOLUME_NAME}/.background"
cp -R "${APP_PATH}" "${STAGING_DIR}/${VOLUME_NAME}/${APP_NAME}"
ln -s /Applications "${STAGING_DIR}/${VOLUME_NAME}/Applications"

# 2. 生成背景图（660x400，顶部蓝色渐变）——想用自己的图，直接 cp 到 .background/background.png
BG_DIR="${STAGING_DIR}/${VOLUME_NAME}/.background" python3 << 'PYEOF'
import os
import struct
import zlib

WIDTH, HEIGHT = 660, 400

def make_png():
    pixels = []
    for y in range(HEIGHT):
        row = []
        for x in range(WIDTH):
            # 浅色底 #f5f5f7
            r, g, b, a = 245, 245, 247, 255
            # 顶部渐变条（0-50px）：蓝→底色
            if y < 50:
                t = y / 50.0
                r = int(90 + (245 - 90) * t)
                g = int(130 + (245 - 130) * t)
                b = int(245 + (247 - 245) * t)
            # 底部提示条（360-400px）：微灰
            elif y > 360:
                t = (y - 360) / 40.0
                r = int(245 - 10 * t)
                g = int(245 - 10 * t)
                b = int(247 - 8 * t)
            row.extend([r, g, b, a])
        pixels.append(bytes([0] + row))

    raw = b''.join(pixels)

    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', WIDTH, HEIGHT, 8, 6, 0, 0, 0))
    idat = chunk(b'IDAT', zlib.compress(raw, 9))
    iend = chunk(b'IEND', b'')
    return sig + ihdr + idat + iend

path = os.path.join(os.environ['BG_DIR'], 'background.png')
with open(path, 'wb') as f:
    f.write(make_png())
print(f'[create-dmg] Background saved: {path}')
PYEOF

# 3. 创建可写 DMG 并挂载
echo "[create-dmg] Creating writable DMG..."
hdiutil create -volname "${VOLUME_NAME}" \
  -fs HFS+ -fsargs '-c c=64,a=16,e=16' \
  -size 200m "${DMG_TEMP}"

MOUNT_POINT="/Volumes/${VOLUME_NAME}"
hdiutil attach "${DMG_TEMP}" -nobrowse -mountpoint "${MOUNT_POINT}"

# 4. 复制内容
echo "[create-dmg] Copying files to DMG..."
cp -R "${STAGING_DIR}/${VOLUME_NAME}/.background" "${MOUNT_POINT}/"
cp -R "${STAGING_DIR}/${VOLUME_NAME}/${APP_NAME}" "${MOUNT_POINT}/"
cp -R "${STAGING_DIR}/${VOLUME_NAME}/Applications" "${MOUNT_POINT}/"

# 5. Finder 窗口布局（失败非致命：CI 无头环境跳过布局不影响产物）
echo "[create-dmg] Configuring Finder layout..."
osascript << APPLESCRIPT || echo "[create-dmg] Warning: Finder layout failed (non-fatal)"
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 760, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:background.png"
        set position of item "${APP_NAME}" of container window to {160, 220}
        set position of item "Applications" of container window to {500, 220}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# 6. 同步并卸载
echo "[create-dmg] Finalizing..."
sync
hdiutil detach "${MOUNT_POINT}" -quiet
MOUNT_POINT=""

# 7. 转换为压缩只读 DMG
echo "[create-dmg] Converting to compressed DMG..."
mkdir -p "$(dirname "${OUTPUT_PATH}")"
hdiutil convert "${DMG_TEMP}" -format UDZO \
  -imagekey zlib-level=9 \
  -o "${OUTPUT_PATH}"

# 8. Ad-hoc 签名
codesign --force --deep --sign - "${OUTPUT_PATH}"

echo "[create-dmg] Done: ${OUTPUT_PATH}"
ls -lh "${OUTPUT_PATH}"
