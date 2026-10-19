# LinkDeck 앱 API 연결

## 등록

1. `./script/build_and_run.sh`로 빌드합니다.
2. LinkDeck 버튼에 작업 폴더 최상단의 `ShareStackMac.app`을 **앱 실행**으로 등록합니다.
3. 최초 앱 API 연결 승인을 완료합니다. **설정 → ChatGPT 연결 → 등록된 앱 API**에서 Share Stack을 확인합니다.
4. ChatGPT 연결 중 추가했다면 도구 목록을 새로고침합니다.

앱 위치 또는 안내 JSON이 바뀌면 LinkDeck에서 다시 승인해야 합니다. 앱은 기존 TLS·짝 토큰을 앱 자체 Keychain에 보관합니다. LinkDeck의 OpenAI 키는 필요하지 않습니다. Keychain 접근이 차단되면 먼저 GUI 앱을 열어 접근을 허용한 뒤 다시 호출합니다.

실제 배포 리소스는 `ShareStackMac.app/Contents/Resources/linkdeck.json`입니다. LinkDeck은 같은 번들의 `Contents/MacOS/ShareStackMac`에 `--mcp`를 전달합니다. 셸이나 별도 인터프리터를 사용하지 않습니다.

## 구조

`LinkDeck → 앱 실행 파일 --mcp → 인증된 루프백 HTTPS → GUI의 실제 저장소·작업 실행기`

MCP 모드는 메뉴바 아이콘이나 두 번째 저장소를 만들지 않습니다. 조회 때 GUI가 없으면 현재 앱 번들을 실행하고 준비를 기다립니다. GUI의 기존 HTTPS API를 그대로 사용하며, 인증서 SHA-256을 확인하고 Keychain 토큰으로 인증합니다. 인증서 지문만 담긴 `gui-bridge.json`은 앱 데이터 폴더에 권한 0600으로 저장하며 비밀 토큰은 저장하지 않습니다.

각 JSON-RPC 요청의 연결·응답 대기는 합계 8초로 제한합니다. GUI 준비가 늦거나 바쁘면 10초를 넘겨 기다리지 않고 MCP 도구 오류로 반환하므로 다시 조회할 수 있습니다. 오래 걸리는 파일 작업은 즉시 작업 ID를 반환합니다.

## 도구

LinkDeck에서 노출되는 이름에는 `linkdeck_app_share_stack__`이 붙습니다.

| 도구 | 입력 | 실제 동작 |
|---|---|---|
| `get_status` | 없음 | GUI 수신 설정, 연결 주소, 수신·송신 대기 개수 |
| `list_inbox` | `limit`, `offset` 선택 | 임시 보관 파일 목록 |
| `get_item` | `id` | 파일 상태·저장 경로·오류 조회 |
| `list_history` | `limit`, `offset` 선택 | 전송·저장 기록 |
| `list_outbox` | `limit`, `offset` 선택 | 휴대전화 송신 대기열 |
| `list_events` | `after`, `streamID` 함께 선택 | 앱의 파일 이벤트 |
| `receive_files` | `ids` 배열 | 개별·선택 파일 수신 작업 시작 |
| `receive_all` | 없음 | 실행 시점의 모든 보관함 파일 수신 시작 |
| `cancel_inbox_files` | `ids` 배열 | 선택한 임시 파일과 항목 삭제 작업 |
| `cancel_outbox_files` | `ids` 배열 | 아직 전송 대기 중인 앱 사본과 항목 삭제 작업. 원본 보존 |
| `send_text` | `text` | 휴대전화로 보낼 텍스트 대기열 추가 작업 |
| `send_files` | `paths` 배열 | 로컬 파일을 휴대전화 송신 대기열에 복사하는 작업 |
| `add_inbox_files` | `paths` 배열 | 다른 앱의 로컬 파일을 실제 수신 흐름으로 추가. 수신 설정 적용 |
| `get_job` | `id` | 작업 진행률·결과·항목별 실패 조회 |
| `list_jobs` | `limit`, `offset` 선택 | 저장된 작업과 결과 목록 |
| `cancel_job` | `id` | 처리하지 않은 나머지 항목의 취소 요청 |

`limit`은 1–100(기본 50), `offset`은 0 이상입니다. 목록에 `nextOffset`이 있으면 다음 페이지로 조회합니다. 도구 정의 자체도 `tools/list`의 `nextCursor`로 7개씩 페이지 분할됩니다. 각 도구는 설명, 정확한 입력 스키마, 읽기·파괴·멱등·외부 접근 annotations를 반환합니다.

## 작업과 결과

작업 시작 도구의 응답 `id`로 `get_job`을 호출합니다. `total`, `completed`, `results`, `failures`가 실제 GUI 처리 결과입니다. 결과 항목의 `savedPath`가 최종 저장 위치입니다.

- 진행 상태: `queued`, `running`, `cancelling`
- 종료 상태: `succeeded`, `partial_failure`, `failed`, `cancelled`, `interrupted`

작업·결과는 `~/Library/Application Support/ShareStackMac/jobs`에 권한 0600으로 저장합니다. MCP 프로세스가 끝나도 GUI 작업은 계속됩니다. GUI 재시작 때 완료된 결과는 유지하고, 중단된 작업은 `interrupted`로 표시합니다. 중단 작업을 자동으로 재실행하지 않습니다.

취소는 항목 사이에서 반영됩니다. 이미 진행 중인 파일 이동·복사는 완료될 수 있으며 완료된 저장이나 송신 대기열 추가는 되돌리지 않습니다. 대기열에 들어간 파일을 철회하려면 `cancel_outbox_files`를 사용합니다. 작업 성공은 휴대전화의 실제 수신 완료를 뜻하지 않습니다. 휴대전화가 **받기**를 실행한 뒤 `get_item`의 `state`가 `delivered`인지 확인합니다.

파일은 절대 경로의 일반 파일만 허용하며 심볼릭 링크는 제외합니다. 한 작업은 파일 경로 16개 또는 항목 ID 100개까지 받습니다. 실제 파일 크기 제한은 기존과 같은 20 GiB입니다. 임의 저장 폴더 지정은 허용하지 않고 GUI 설정을 사용합니다. 임시 파일 삭제 도구는 사용자가 명시한 항목에만 호출합니다.

## 내부 작업 API

기존 [HTTP API](api.md)에 다음 GUI 작업 경로를 추가했습니다. 같은 TLS·Bearer 인증이 필요하며 **루프백 연결에서만** 사용할 수 있습니다. LinkDeck과 직접 통신하는 전송 방식은 여전히 MCP stdio입니다.

- `POST /v1/jobs`: JSON `operation`과 `itemIDs`·`filePaths`·`text`로 작업 생성
- `GET /v1/jobs?limit=50&offset=0`: 작업 목록
- `GET /v1/jobs/{id}`: 진행 상태와 결과
- `POST /v1/jobs/{id}/cancel`: 나머지 항목 취소 요청
- `GET /v1/items/{id}`: 기존 항목의 메타데이터 조회

작업 `operation`은 `receive`, `receiveAll`, `cancelInbox`, `cancelOutbox`, `sendText`, `sendFiles`, `importFiles`입니다. 이벤트에는 `outbox.cancelled`도 포함됩니다.

## 검증

```sh
python3 -u script/verify_mcp.py --bundle ShareStackMac.app
```

실제 번들 실행 파일을 자식 프로세스로 띄워 JSON-RPC 줄 단위 입출력, 초기화, 알림, 도구 목록 페이지, 입력 오류, GUI 자동 실행과 재연결, 파일·텍스트 대기열, 수신·전체 수신·삭제·작업 취소, 결과 유지와 manifest 일치를 확인합니다. 검증은 고유한 이름의 합성 파일만 만들고 원본 파일을 보존합니다. 기존 보관함 파일이 있으면 안전을 위해 전체 수신 검증을 생략합니다.

MCP stdout에는 JSON-RPC만 출력하고 로그는 stderr로 보냅니다. EOF로 MCP 프로세스를 종료해도 GUI는 유지됩니다. JSON 안내 파일에는 경로, 토큰, 키 또는 인증 정보가 들어가지 않습니다.
