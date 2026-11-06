#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"
echo "OpenAnyway"
echo "开始在本机使用 Xcode 构建..."
if ! xcode-select -p >/dev/null 2>&1 || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "错误：没有找到 Xcode 构建工具。请先从 App Store 安装 Xcode 并完成首次启动。"
  read -r -p "回车退出..." _
  exit 1
fi
if xcodebuild -project MacAppDoctor.xcodeproj -scheme MacAppDoctor \
  -configuration Debug -derivedDataPath "$PROJECT_DIR/DerivedData" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES build; then
  APP_PATH="$PROJECT_DIR/DerivedData/Build/Products/Debug/OpenAnyway.app"
  if [ -d "$APP_PATH" ]; then
    echo "构建成功，启动 OpenAnyway..."
    open "$APP_PATH"
    echo "应用位置：$APP_PATH"
  else
    echo "构建结束，但找不到 APP。请在 Xcode 中检查生成目录。"
  fi
else
  echo "构建失败，请查看终端错误信息，或使用 Xcode 打开工程。"
fi
read -r -p "回车关闭此窗口..." _
