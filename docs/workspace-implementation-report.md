# 폴더 작업공간 구현 검증 보고

## 구현 범위

M1–M3 구현. M4 원본 반영은 지시문의 허용된 보류 범위이며 UI/API 모두 비활성화. 원본 경로를 저장하거나 MCP로 받거나 반환하지 않음.

- M1: 표준 폴더 선택기, 포함/제외 요약 승인, 비공개 독립 복사, UUID·baseline SHA-256·버전, 0700/0600, 크기/깊이/개수/디스크 검사, 실패 정리. 디렉터리 descriptor에 고정한 openat/mkdirat/renameat/unlinkat로 부모 경로 교체와 링크를 방어. 하드링크는 독립 복사.
- M2: GUI 전용 모드 변경·연결 승인 취소·삭제. 각 MCP 프로세스는 서버가 발급한 독립 pending credential을 받고 GUI가 작업공간에 바인딩. 전화/다른 세션/미승인/비공개 접근 거부. 세션은 앱 재시작 시 사라지며 모드는 유지. inode별 승인으로 관리 root 교체가 기존 승인을 상속하지 못함. UTF-8 텍스트만 본문 허용, 바이너리는 메타데이터만. 전체 AI 읽기 중지 적용.
- M3: 엄격한 단일 파일 unified diff parser, create, expectedHash CAS, persistent requestKey fingerprint/replay, 불변 payload + 원자적 manifest commit, baseline diff와 GUI diff 검토. 모드/세션 세대를 commit 직전에 재확인하여 중간 권한 변경을 거부. 원본 변경 없음.
- 기존 절대 경로 HTTP sendFiles/importFiles jobs는 복사본 우회 방지를 위해 차단. GUI 파일 선택·Finder 공유·전화 바이트/조각 전송·텍스트 교환 경로는 유지.

## 변경 파일

WorkspaceStore.swift, ReceiptViews.swift, TransferStore.swift, TransferHTTPServer.swift, GUIBridge.swift, MCPServer.swift, Resources/linkdeck.json, Xcode project, workspace regression tests/scripts, 기존 회귀 스크립트의 source 목록, README/API/MCP/OpenAPI 문서.

## 도구와 UI

MCP 도구: list_workspaces, list_workspace_entries, get_workspace_file_info, read_workspace_file, list_workspace_changes, apply_workspace_patch, create_workspace_text_file.

설정 → 폴더 작업공간 → 폴더 추가 → 요약 확인. AI에서 list_workspaces → 응답 sessionId와 같은 GUI 연결 선택 → 읽기 전용 또는 격리 편집 승인. 변경 내용 확인에서 diff 검토. 비공개/승인 취소/삭제로 차단. 새 보고서를 AI가 읽으려면 보관함에서 해당 파일의 AI 읽기 허용 체크 필요.

## 실행 증거

- verify_workspace.sh: PASS. 세션 격리, 비공개, UTF-8 한국어/일본어/이모지 복원, 읽기 전용 write 거부, CAS, 중복 키, 경로 탈출, baseline diff, 원본 보존, 프로세스 재시작, 관리 root 교체, 복사 상한/실패 정리, 동시 중복 요청, 편집 중 권한 하향, 하드링크 독립 복사.
- verify_workspace_http.sh: PASS (샌드박스 밖 임시 TLS 서버, 사용자 보관함/설정 미사용). 실제 HTTPS pending/승인 세션 격리, 전화 인증 거부, 읽기 전용 거부, 권한 승격 경로 부재, legacy 절대경로 우회 거부, 편집/replay, 전체 AI 읽기 중지, 비공개 전환, 정상 텍스트 수신.
- 통합 Debug Xcode 빌드: PASS. 검토 수정 후 최종 소스 빌드도 exit 0.
- 기존 회귀: verify_phone_ai_read.sh, verify_phone_delivery.sh, verify_ai_read_android.sh, verify_library_arrival.sh PASS.
- verify_mcp.py --bundle /private/tmp/sharestack-workspace-build/Build/Products/Debug/ShareStackMac.app: PASS. 정확한14개 도구와 번들 manifest 일치, 입력 검증·도구 페이지·제거 도구 차단.
- OpenAPI YAML: PyYAML safe_load PASS.
- 검토 발견사항 수정: 빈 디렉터리 이름 충돌 차단, 동시 create의 파일/키 상한 재검사, diff 응답 페이지/UTF-8 청크 상한. 해당 회귀 모두 PASS.

최종 재검증: workspace core 회귀, 실제 HTTPS(HTTP patch/diff와 기존 item/accept/delete 경로의 작업공간 우회 거부 포함), Mac Debug 빌드, 14개 MCP 프로토콜 검사 모두 PASS. 검토의 세 수정사항에 대한 재검토도 clean. 실행 중 사용자 앱과 파일은 변경하지 않음.

## 한계/미검증

- M4 원본 반영, 파일 삭제/이름 변경, 폴더 Finder 공유 확장은 의도적으로 미지원. 폴더는 GUI에서 등록.
- 실제 GUI 클릭/화면의 수동 QA와 실물 Galaxy 기기의 무선 전송은 수행하지 않음. 기존 자동 회귀로 검증하며 실행 중 사용자 앱은 교체/재실행하지 않음.
- 파일명 기반 기본 비밀 제외는 모든 비밀 내용을 자동 탐지하지 않음. 사용자가 원본과 포함·제외 요약을 검토해야 함.
- 초기 상한: 32 작업공간, 폴더당 10,000 파일/20,000 탐색 항목/깊이32/1 GiB, 파일100 MiB, 입력128 KiB, 요청 키1000개, pending 세션32개/24시간. 디스크 부족은 실패로 처리.
- Xcode의 기존 headermap 경고와 설치된 CoreSimulator 버전 불일치 경고가 있었으나 Mac 빌드 대상 검증과 별개.

변경사항 조회는 `cursor`(기본 `0:0`)와 `limit`(기본20, 최대100)으로 페이지를 이어갑니다. `diffOffset` 순서로 같은 파일의 `diff`를 합치고 `nextCursor`가 없어질 때까지 조회합니다. diff 청크는 256 KiB, 페이지 전체 diff는 1 MiB로 제한하며 UTF-8 문자를 나누지 않습니다. GUI는 첫 페이지를 미리보기하고 추가 페이지 존재를 표시합니다. 격리 편집의 입력과 결과 파일은 각각 128 KiB/1 MiB 상한이며, 더 큰 파일(최대100 MiB)은 읽기 전용 분석만 지원합니다.
