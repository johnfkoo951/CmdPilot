#!/bin/bash
# MacPilot 헬퍼를 Release 로 빌드해 ~/Applications 에 설치하고 LaunchAgent 를 재시작.
# 코드 수정 후 이 스크립트 한 번이면 상시 서버가 갱신된다. (Xcode 불필요)
set -e
cd "$(dirname "$0")"

echo "▸ 프로젝트 생성 + Release 빌드(ad-hoc)…"
xcodegen generate >/dev/null
xcodebuild -project MacPilot.xcodeproj -scheme MacPilotHelper -configuration Release \
  -derivedDataPath ./.release CODE_SIGNING_ALLOWED=NO build >/dev/null

# 키체인의 Apple Development 인증서로 재서명 → 고정 서명(손쉬운 사용 권한 유지).
# (xcodebuild 자동서명은 CLI에서 계정 세션을 못 잡아 실패하므로 codesign 으로 직접 서명)
# 인증서 조회가 가끔 깜빡이므로 재시도 + 결과 검증.
APP_SRC="./.release/Build/Products/Release/MacPilot Helper.app"
signed=0
for attempt in 1 2 3 4; do
  CERT=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | awk '{print $2}')
  if [ -n "$CERT" ]; then
    codesign --force --deep --sign "$CERT" "$APP_SRC" >/dev/null 2>&1
    if codesign -dvv "$APP_SRC" 2>&1 | grep -q "Apple Development"; then
      echo "▸ 인증서 재서명 OK ($CERT)"; signed=1; break
    fi
  fi
  sleep 1
done
if [ "$signed" != "1" ]; then
  echo "  ⚠️  재서명 실패 → ad-hoc. 수동: codesign --force --deep --sign <인증서> '$HOME/Applications/MacPilot Helper.app' 후 launchctl kickstart"
  exit 1
fi

echo "▸ ~/Applications 갱신…"
rm -rf "$HOME/Applications/MacPilot Helper.app"
ditto "./.release/Build/Products/Release/MacPilot Helper.app" "$HOME/Applications/MacPilot Helper.app"

echo "▸ 서버 재시작…"
launchctl kickstart -k "gui/$(id -u)/com.joonlab.macpilot.helper"

echo "✅ 배포 완료 — http://$(scutil --get LocalHostName).local:8765"
