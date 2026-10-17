#!/bin/bash
# Собирает HWMonitor.app из Sources/*.swift (нужны Command Line Tools: xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

APP="HWMonitor.app"
BUNDLE_ID="local.hwmonitor"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "Не найден swiftc. Установите Command Line Tools: xcode-select --install" >&2
    exit 1
fi

# Если эта сборка запущена — закрываем только её (копию в /Applications не трогаем).
# По SIGTERM приложение само вернёт приоритеты замедленным процессам.
if pkill -f "$PWD/$APP/Contents/MacOS/HWMonitor" 2>/dev/null; then sleep 1; fi

echo "→ Компилирую…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
    -import-objc-header Sources/Bridge.h Sources/*.swift -lIOReport \
    -o "$APP/Contents/MacOS/HWMonitor"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>HWMonitor</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>HWMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>ru</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Иконка: свой icon.png (1024×1024) можно положить рядом; если его нет — рисуем стандартную.
if [ ! -f icon.png ]; then
    echo "→ Рисую иконку…"
    swift MakeIcon.swift icon.png
fi
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "→ Подписываю локально…"
codesign --force --sign - "$APP"

# Чтобы Finder сразу показал новую иконку, а не старую из кэша.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" >/dev/null 2>&1 || true

echo "✓ Готово: $(pwd)/$APP"
echo "  Запуск: open \"$APP\""
