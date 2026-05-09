#!/bin/bash
# AorusGram build setup
# Клонирует Telegram iOS, применяет наши патчи и готовит к сборке через Bazel.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TG_DIR="$REPO_ROOT/telegram-ios"
PATCHES_DIR="$REPO_ROOT/patches"
AORUS_SRC="$REPO_ROOT/AorusGram/Sources"

echo "=== AorusGram Build Setup ==="

# 1. Клонируем Telegram iOS если ещё нет
if [ ! -d "$TG_DIR" ]; then
  echo "[1/5] Cloning Telegram iOS..."
  git clone --depth=1 https://github.com/TelegramMessenger/Telegram-iOS.git "$TG_DIR"
else
  echo "[1/5] Telegram iOS already cloned, pulling latest..."
  git -C "$TG_DIR" pull --ff-only || true
fi

# 2. Устанавливаем зависимости (на macOS CI)
echo "[2/5] Installing dependencies..."
if command -v brew &>/dev/null; then
  brew install bazel python3 cmake || true
fi

# 3. Копируем наши файлы в нужные места Telegram iOS
echo "[3/5] Injecting AorusGram sources..."

SUBMODULES_DIR="$TG_DIR/submodules"
TELEGRAM_APP_DIR="$TG_DIR/Telegram"

# Core файлы
mkdir -p "$TELEGRAM_APP_DIR/Watch/Extension/AorusGram"
cp -r "$AORUS_SRC/Core/"*          "$TELEGRAM_APP_DIR/Watch/Extension/AorusGram/"
cp -r "$AORUS_SRC/Features/"*      "$TELEGRAM_APP_DIR/Watch/Extension/AorusGram/"
cp -r "$AORUS_SRC/UI/"*            "$TELEGRAM_APP_DIR/Watch/Extension/AorusGram/"

# Более точное место для основного приложения
MAIN_TARGET="$TELEGRAM_APP_DIR/Telegram-iOS"
if [ -d "$MAIN_TARGET" ]; then
  mkdir -p "$MAIN_TARGET/AorusGram"
  cp -r "$AORUS_SRC/Core/"*     "$MAIN_TARGET/AorusGram/"
  cp -r "$AORUS_SRC/Features/"* "$MAIN_TARGET/AorusGram/"
  cp -r "$AORUS_SRC/UI/"*       "$MAIN_TARGET/AorusGram/"
fi

# 4. Применяем патчи
echo "[4/5] Applying patches..."
if ls "$PATCHES_DIR"/*.patch &>/dev/null; then
  for patch in "$PATCHES_DIR"/*.patch; do
    echo "  Applying $patch..."
    git -C "$TG_DIR" apply --ignore-space-change --ignore-whitespace "$patch" || \
      echo "  Warning: patch $patch failed, skipping"
  done
else
  echo "  No patches found, skipping"
fi

# 5. Патч имени и иконки приложения
echo "[5/5] Patching app name and icon..."
INFO_PLIST="$TG_DIR/Telegram/Telegram-iOS/Info.plist"
if [ -f "$INFO_PLIST" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName AorusGram" "$INFO_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleName AorusGram"        "$INFO_PLIST" 2>/dev/null || true
fi

# Генерируем иконку
bash "$REPO_ROOT/AorusGram/Resources/Icons/generate_icon.sh" 2>/dev/null || true

echo ""
echo "=== Setup complete! ==="
echo "Next: run GitHub Actions workflow or manually:"
echo "  cd telegram-ios && python3 build-system/Make/Make.py build"
