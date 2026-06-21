#!/bin/bash
# MacPilot 헬퍼를 Release 로 빌드해 ~/Applications 에 설치하고 LaunchAgent 를 재시작.
# 코드 수정 후 이 스크립트 한 번이면 상시 서버가 갱신된다. (Xcode 불필요)
set -e
cd "$(dirname "$0")"

echo "▸ 프로젝트 생성 + Release 빌드…"
xcodegen generate >/dev/null
xcodebuild -project MacPilot.xcodeproj -scheme MacPilotHelper -configuration Release \
  -derivedDataPath ./.release -allowProvisioningUpdates build >/dev/null

echo "▸ ~/Applications 갱신…"
rm -rf "$HOME/Applications/MacPilot Helper.app"
ditto "./.release/Build/Products/Release/MacPilot Helper.app" "$HOME/Applications/MacPilot Helper.app"

echo "▸ 서버 재시작…"
launchctl kickstart -k "gui/$(id -u)/com.joonlab.macpilot.helper"

echo "✅ 배포 완료 — http://$(scutil --get LocalHostName).local:8765"
