#!/bin/bash
# CmdPilot 헬퍼를 Release 로 빌드해 ~/Applications 에 설치하고 LaunchAgent 를 (없으면 만들어서) 재시작.
# 코드 수정 후 이 스크립트 한 번이면 상시 서버가 갱신된다. (Xcode 불필요)
set -e
cd "$(dirname "$0")"

APP_NAME="CmdPilot Helper"
LABEL="com.cmdspace.cmdpilot.helper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# 포트는 HelperServer.swift 의 상수에서 자동 감지 (이 머신은 8766 — 8765는 OmniControl 이 사용)
PORT=$(sed -n 's/.*let port: UInt16 = \([0-9][0-9]*\).*/\1/p' MacHelper/Sources/HelperServer.swift)
PORT=${PORT:-8765}

echo "▸ 프로젝트 생성 + Release 빌드(서명 없이)…"
xcodegen generate >/dev/null
xcodebuild -project CmdPilot.xcodeproj -scheme CmdPilotHelper -configuration Release \
  -derivedDataPath ./.release CODE_SIGNING_ALLOWED=NO build >/dev/null

APP_SRC="./.release/Build/Products/Release/$APP_NAME.app"

# 서명: 키체인에 Apple Development 인증서가 있으면 고정 서명(손쉬운 사용 권한이 재빌드 후에도 유지),
# 없으면 ad-hoc 서명 — 동작은 하지만 재빌드 때마다 손쉬운 사용 권한을 다시 켜야 한다.
# (인증서 조회가 가끔 깜빡이므로 재시도)
CERT=""
for attempt in 1 2 3 4; do
  CERT=$(security find-identity -v -p codesigning 2>/dev/null | grep -E "Apple Development|CmdSpace Local Signing" | head -1 | awk '{print $2}')
  [ -n "$CERT" ] && break
  sleep 1
done
if [ -n "$CERT" ] && codesign --force --deep --sign "$CERT" "$APP_SRC" >/dev/null 2>&1 \
   && codesign -dvv "$APP_SRC" 2>&1 | grep -qE "Apple Development|CmdSpace Local Signing"; then
  echo "▸ 인증서 재서명 OK ($CERT)"
else
  codesign --force --deep --sign - "$APP_SRC" >/dev/null 2>&1
  echo "  ⚠️  Apple Development 인증서 없음 → ad-hoc 서명."
  echo "     재빌드마다 손쉬운 사용 권한 재부여 필요: 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → '$APP_NAME' 껐다 켜기"
  echo "     (Xcode 에 Apple ID 로그인해 인증서를 만들면 이 번거로움이 사라짐)"
fi

echo "▸ ~/Applications 갱신…"
rm -rf "$HOME/Applications/$APP_NAME.app"
ditto "$APP_SRC" "$HOME/Applications/$APP_NAME.app"

# LaunchAgent: plist 가 없으면 생성 (로그인 시 자동 시작 + 죽으면 자동 재시작)
if [ ! -f "$PLIST" ]; then
  echo "▸ LaunchAgent 생성…"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/CmdPilot"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/CmdPilot/helper.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/CmdPilot/helper.log</string>
</dict>
</plist>
PLISTEOF
fi

echo "▸ 서버 재시작…"
# launchd 밖에서 직접 실행된 인스턴스가 있으면 종료 (포트 충돌 방지)
pkill -f "$APP_NAME.app/Contents/MacOS" 2>/dev/null || true
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
else
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi

echo "✅ 배포 완료 — http://$(scutil --get LocalHostName).local:$PORT"
