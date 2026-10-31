# GUI 연결 준비 실패 수정

원인: 실행 중 GUI가 8765 포트의 일시적인 점유 충돌(EADDRINUSE)로 NWListener 실패 상태에 들어간 뒤 재시도하지 않았습니다. GUI 프로세스는 살아 있었지만 이전 포트 소유자가 종료된 뒤에도 리스너가 없어 MCP가 connection refused를 받고 준비 제한 시간을 넘겼습니다.

실제 증거: GUI PID59836 시스템 로그 2026-10-31 17:04:55에 NECP/NWListener error48 Address already in use. 점검 시 GUI/MCP 프로세스는 존재했으나 TCP8765 리스너는 없었고 TLS health 연결은 실패했습니다. 인증서 descriptor는 생성되어 있었으므로 토큰/인증서 초기화 이전 문제가 아니었습니다.

수정: TransferHTTPServer의 EADDRINUSE 실패만 0.25초부터 최대4초의 backoff로 새 NWListener를 구성해 재시도합니다. 이전 리스너의 늦은 콜백이 현재 상태를 덮지 않도록 identity를 확인합니다. 다른 오류는 기존 오류 보고를 유지합니다. GUIBridge, 토큰, Keychain, 인증서 저장 방식은 변경하지 않았습니다.

검증:
- verify_listener_recovery.sh: 수정 전 포트 점유→해제 뒤 "Listener never recovered"로 실패; 수정 후 PASS.
- verify_workspace_http.sh: 실제 임시 TLS 서버의 인증/세션/읽기 전용/우회 차단/편집 회귀 PASS.
- 기존 인증서를 재사용한 Release 서명 빌드 PASS. 작업 폴더와 /Applications의 앱 업데이트 및 codesign --verify --deep --strict PASS.
- 재실행한 설치 GUI가 TCP8765 LISTEN 상태에 도달. 재실행 초기에는 macOS Keychain 접근 승인 대기가 있었고 승인 이후 준비됨.
- /Applications 실제 MCP list_shared_files 호출 isError:false, 이어 실제 LinkDeck 도구 호출도 성공(부모 에이전트 확인).
- 사용자 보관함 items.json 기록14건 존재. AI Exchange/index.json 승인 파일0건이므로 빈 AI 목록은 현재 체크 상태와 일치합니다. 내용/파일명/토큰을 로그에 출력하지 않았습니다. TLS archive 수정 시각은 이번 수정 이전이며 인증 파일 재생성/토큰 초기화는 하지 않았습니다.

실물 Galaxy 송수신은 다시 수행하지 않았습니다. 이미 승인된 파일만 AI 목록에 표시되는 기존 정책은 유지됩니다.
