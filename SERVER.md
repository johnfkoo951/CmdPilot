# MacPilot 상시 서버 (launchd)

Xcode 없이 **로그인 시 자동 시작 + 죽으면 자동 재시작**으로 항상 돌아가는 서버.
(pm2 의 macOS 네이티브 등가물 = `launchd` LaunchAgent. GUI 세션에서 돌아야 손쉬운 사용 권한이 동작하므로 데몬이 아니라 **사용자 LaunchAgent**를 사용.)

## 구성
- 앱: `~/Applications/MacPilot Helper.app` (Apple Development 서명, 고정)
- LaunchAgent: `~/Library/LaunchAgents/com.joonlab.macpilot.helper.plist`
  - `RunAtLoad`(로그인 시 시작) + `KeepAlive`(상시 상주/재시작)
- 접속: `http://<your-mac-name>.local:8765` (mDNS — IP 바뀌어도 고정). 정확한 주소는 `echo http://$(scutil --get LocalHostName).local:8765`

## 관리 명령
```bash
UID=$(id -u); PLIST=~/Library/LaunchAgents/com.joonlab.macpilot.helper.plist

# 상태 확인
launchctl print gui/$UID/com.joonlab.macpilot.helper | grep -E "state|pid"

# 중지 (자동 재시작 포함 완전 정지)
launchctl bootout gui/$UID "$PLIST"

# 시작
launchctl bootstrap gui/$UID "$PLIST"

# 재시작만
launchctl kickstart -k gui/$UID/com.joonlab.macpilot.helper
```

## 코드 수정 후 업데이트
```bash
./deploy.sh      # Release 빌드 → ~/Applications 갱신 → 재시작
```

## 주의
- **Mac 이 깨어 있고 같은 Wi-Fi** 에 있어야 폰에서 접속됨 (잠자면 서버도 잠듦).
- 첫 실행 후 **손쉬운 사용 권한 1회 부여** 필요 (고정 서명이라 이후 유지). 메뉴바 아이콘 → "권한 요청".
- **Xcode 에서 Run 하지 말 것** — 8765 포트가 겹쳐 충돌남. 이제 상시 서버가 그 역할.
- 재부팅 후엔 **사용자 로그인** 시 자동 시작 (자동 로그인이면 부팅 직후).
