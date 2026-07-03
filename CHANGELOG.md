# Changelog — CmdSpace Pilot

> upstream [joonlab/MacPilot](https://github.com/joonlab/MacPilot)의 브랜디드 포크.
> 여기에는 포크 이후의 변경만 기록합니다.

## v0.4.0 — 2026-07-03

### 🤖 에이전트 원격 (cmux · Claude Code) — 포크 시그니처 기능
- **에이전트 탭** 신설: 침대에서 코딩 에이전트를 승인/조종하는 모드
  - 큰 제어 버튼: ⏎ 입력·승인 / esc 중단 / ⌃C 강제 중단, ↑↓⇥·y⏎·n⏎
  - 빠른 지시(누르면 타이핑+엔터까지 자동): 계속해줘 · 진행상황 요약 · /compact · /clear · 테스트 실행 · 커밋해줘
- **cmux 브리지** (`CmuxBridge.swift`): cmux RPC 직접 호출로 **창·워크스페이스·탭 전환**
  - 워크스페이스가 이름+색상 칩으로 표시, 탭 제목으로 에이전트 상태 확인
  - 화이트리스트 4개 동사만 허용, UUID 검증, 셸 미경유 — 무인증 LAN 서버에 안전하게 통합
  - 소켓 인증: cmux `automation.socketPassword`를 로컬에서만 읽음 (폰에 미노출)
  - 에이전트 탭 표시 중 4초 자동 갱신 (변경 없으면 리렌더 생략)

### 🖱 커서 반응성/부드러움
- **TCP_NODELAY + `.responsiveData`**: Nagle이 move 프레임을 뭉치던 "낮은 주사율 느낌"의 근본 원인 제거
- **모션 전송 큐**: 프레임 단위 델타 병합, 리딩엣지 즉시 전송(rAF 대기 지연 제거)
- **RTT 자동 네트워크 프리셋(기본값)**: 3초 핑 측정으로 전송 주사율 36–120Hz 자동 조정
  - 수동 프리셋(빠른 Wi-Fi 120Hz/균형/불안정) + 주사율·보정·해상도 배율 슬라이더
- `EventInjector.move` 위치 조회 1회로 축소

### 📱 접속/레이아웃
- **PWA**: manifest + 홈 화면 아이콘 → 원탭 전체화면(standalone) 실행
- **가시 높이 추적(`--app-height`)**: 사파리 주소창 접힘/웹앱 모드의 하단 빈 공간 해결
- **트랙패드 시트 디텐트**: 풀/45%/70%/닫힘 스냅 + 높이 기억 → 덱과 레이어 분할 사용
- **화면 모드**: 자동(폭 640px)/폰/태블릿 — 와이드에서 덱 4열·12버튼
- **Tailscale 원격**: 테일넷 기기라면 어느 네트워크에서든 `…ts.net:8766` 영구 주소로 접속 (코드 변경 불필요, Funnel 금지)
- 안드로이드: IP 접속 가이드 + 햅틱(진동) 피드백

### 🎨 CMDSPACE 브랜딩/UI
- CMDS 라운드 로고(파비콘·터치 아이콘·앱 아이콘 .icns·메뉴 헤더), 브랜드 컬러(다크 Pink `#E985A2` / 라이트 Green `#134538`)
- UI 크롬 아이콘 전부 SF Symbols 풍 인라인 SVG (탭바·퀵바·미디어바·설정)
- **퀵바** 신설(상시 노출): superwhisper ⌥Space · Raycast ⇧Space · 앱 전환 · 미션 컨트롤 · 캡처
- 메뉴바 아이콘 상태 표시: 권한 없음 ⚠️ / 서버 다운 / 정상 📡
- 네이티브 메뉴 UI: 상태 타일·QR·권한 패널·PIN 페어링·서버 제어 (SwiftUI + SF Symbols)

### 🛠 운영/개발 루프
- **LaunchAgent 상시 서버**: 로그인 자동 시작 + 자동 재시작, `deploy.sh`가 plist 자동 생성
- `deploy.sh`: Apple 인증서 없으면 ad-hoc 폴백(경고 출력), 포트 자동 감지
- `script/macpilotctl.sh`: status/start/stop/restart/logs/open/url/install/**sync-web**/unsync-web
- **웹 오버라이드 서빙**: `sync-web`으로 웹 수정을 재빌드(=ad-hoc 권한 리셋) 없이 즉시 반영
- 포트 8766 (이 머신에서 8765는 OmniControl 점유)

### ⬆️ upstream 동기화 (2026-07-03 병합)
- 다중 클라이언트 서버 강화: 전용 큐·자산 메모리 캐시·유휴 타임아웃·연결 상한·FD 상향 (박준님, 30대 동시 접속 현장 검증)
- **PIN 페어링**(기본 off): 공용 Wi-Fi에서 6자리 PIN 1회 입력 요구
- Windows 포트(커뮤니티) 문서/코드

### ↩️ upstream에 보낸 PR
- [joonlab#2](https://github.com/joonlab/MacPilot/pull/2) TCP_NODELAY · [joonlab#3](https://github.com/joonlab/MacPilot/pull/3) 웹 오버라이드 서빙 · [joonlab#4](https://github.com/joonlab/MacPilot/pull/4) PWA

## v0.2.0 — 포크 시점 (upstream 기준선)
트랙패드(모멘텀 스크롤·핀치·3손가락 제스처)·유니코드 키보드·스트림덱식 덱(단축키/텍스트/앱/매크로)·덱 서버 동기화·메뉴바 QR — 원작 [Park Joon (JoonLab)](https://github.com/joonlab/MacPilot).
