#!/bin/bash
# 编译并打包 NetSpeed.app（无需 Xcode 工程，只要有 Swift 命令行工具）
set -euo pipefail
cd "$(dirname "$0")"

APP="NetSpeed.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/NetSpeed" main.swift
cp Info.plist "$APP/Contents/"

echo "✅ 构建完成: $(pwd)/$APP"
