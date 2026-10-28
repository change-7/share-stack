# LinkDeck 앱 API 연결

## 등록

1. `./script/build_and_run.sh`로 빌드합니다.
2. LinkDeck 버튼에 작업 폴더 최상단의 `ShareStackMac.app`을 **앱 실행**으로 등록합니다.
3. 최초 앱 API 연결 승인을 완료합니다. **설정 → ChatGPT 연결 → 등록된 앱 API**에서 Share Stack을 확인합니다.
4. ChatGPT 연결 중 추가했다면 도구 목록을 새로고침합니다.

앱 위치 또는 안내 JSON이 바뀌면 LinkDeck에서 다시 승인해야 합니다. 앱은 기존 TLS·짝 토큰을 앱 자체 Keychain에 보관합니다. LinkDeck의 OpenAI 키는 필요하지 않습니다. Keychain 접근이 차단되면 먼저 GUI 앱을 열어 접근을 허용한 뒤 다시 호출합니다.

Finder 공유 메뉴용 Share Extension은 앱과 확장에 App Group `group.com.pdg.sharestack` 권한이 필요합니다. 이 Mac에서는 해당 권한을 포함한 ad-hoc 서명과 `pluginkit` 등록으로 실제 Finder 수신을 확인했습니다. 다른 Mac 배포는 별도 서명·권한 검증이 필요합니다. `./script/build_and_run.sh`의 기본 빌드는 서명을 생략하며, 배포용 서명은 `SHARESTACK_CODE_SIGN_IDENTITY`와 `SHARESTACK_DEVELOPMENT_TEAM`을 설정합니다.

실제 배포 리소스는 `ShareStackMac.app/Contents/Resources/linkdeck.json`입니다. LinkDeck은 같은 번들의 `Contents/MacOS/ShareStackMac`에 `--mcp`를 전달합니다. 셸이나 별도 인터프리터를 사용하지 않습니다.

## 구조

임시 보관 위치는 맥 앱의 **설정 → 임시 보관 폴더**에서 변경합니다. 선택한 위치의 전용 하위 폴더에 기존 대기 파일을 안전하게 옮기며, 보관함에서 취소한 파일은 그 위치에서도 삭제됩니다. 저장 수락 후의 저장 폴더는 별도 설정입니다. Finder 확장의 App Group 전달함은 기존 위치를 유지합니다.

`LinkDeck → 앱 실행 파일 --mcp → 인증된 루프백 HTTPS → GUI의 실제 저장소·작업 실행기`

MCP 모드는 메뉴바 아이콘이나 두 번째 저장소를 만들지 않습니다. 조회 때 GUI가 없으면 현재 앱 번들을 실행하고 준비를 기다립니다. GUI의 기존 HTTPS API를 그대로 사용하며, 인증서 SHA-256을 확인하고 Keychain 토큰으로 인증합니다. 인증서 지문만 담긴 `gui-bridge.json`은 앱 데이터 폴더에 권한 0600으로 저장하며 비밀 토큰은 저장하지 않습니다.

각 JSON-RPC 요청의 연결·응답 대기는 합계 8초로 제한합니다. GUI 준비가 늦거나 바쁘면 10초를 넘겨 기다리지 않고 MCP 도구 오류로 반환하므로 다시 조회할 수 있습니다. 오래 걸리는 파일 작업은 즉시 작업 ID를 반환합니다.

## 도구

LinkDeck에서 노출되는 이름에는 `linkdeck_app_share_stack__`이 붙습니다.

| 도구 | 입력 | 실제 동작 |
|---|---|---|
| `get_status` | 없음 | GUI 수신 설정, 연결 주소, 수신·송신 대기 개수 |
| `list_inbox` | `limit`, `offset` 선택 | 임시 보관 파일 목록 |
| `list_shared_files` | `limit`, `offset` 선택 | ShareStack에 받은 파일 목록. Finder 공유 확장 전송이 진행 중이면 `pendingImportCount`를 확인하고 다시 조회 |
| `get_shared_file_info` | `id` | 파일 크기·MIME·SHA-256·상태 및 텍스트 읽기 가능 여부 |
| `read_shared_file` | `id`, `offset`, `limit` 선택 | UTF-8 파일의 실제 내용 청크. 기본 4 KiB, 최대 32 KiB이며 다음 `nextOffset`으로 이어 읽기 |
| `get_item` | `id` | 대기 중 항목의 상태·저장 오류 조회 |
| `list_outbox` | `limit`, `offset` 선택 | 휴대전화 송신 대기열 |
| `list_events` | `after`, `streamID` 함께 선택 | 앱의 파일 이벤트 |
| `receive_files` | `ids` 배열 | 개별·선택 파일 수신 작업 시작 |
| `receive_all` | 없음 | 실행 시점의 모든 보관함 파일 수신 시작 |
| `cancel_inbox_files` | `ids` 배열 | 선택한 임시 파일과 항목 삭제 작업 |
| `cancel_outbox_files` | `ids` 배열 | 아직 전송 대기 중인 앱 사본과 항목 삭제 작업. 원본 보존 |
| `send_text` | `text` | 휴대전화로 보낼 텍스트 대기열 추가 작업 |
| `send_files` | `paths` 배열 | 로컬 파일을 휴대전화 송신 대기열에 복사하는 작업 |
| `add_inbox_files` | `paths` 배열 | 다른 앱의 로컬 파일을 실제 수신 흐름으로 추가. 수신 설정 적용 |
| `receive_text_file` | `filename`, `content` | UTF-8 텍스트 내용을 파일로 복원해 기존 수신함 또는 자동 저장 폴더에 추가 |
| `get_job` | `id` | 실행 중 또는 보관 중인 완료 작업의 상태·처리 개수·실패 항목 조회 |
| `cancel_job` | `id` | 처리하지 않은 나머지 항목의 취소 요청 |

`limit`은 1–100(기본 50), `offset`은 0 이상입니다. 목록에 `nextOffset`이 있으면 다음 페이지로 조회합니다. 도구 정의 자체도 `tools/list`의 `nextCursor`로 7개씩 페이지 분할됩니다. 각 도구는 설명, 정확한 입력 스키마, 읽기·파괴·멱등·외부 접근 annotations를 반환합니다.

## 작업과 결과

작업 시작 도구의 응답 `id`로 `get_job`을 호출합니다. `total`, `completed`는 처리 개수입니다. 완료 후 10분 동안 최대 20개의 작업 상태·처리 개수·실패 내용을 메모리에 보관합니다. 개수 제한을 넘으면 완료 시각이 오래된 작업부터 제거하며, 실행 중 작업은 이 제한에서 제외합니다. 만료된 작업은 not found를 반환합니다. 파일 결과나 저장 경로 목록은 보관하지 않습니다. `list_inbox`와 `list_outbox`로 현재 남아 있는 파일을 확인합니다.

- 진행 상태: `queued`, `running`, `cancelling`
- 종료 상태: `succeeded`, `partial_failure`, `failed`, `cancelled`

작업·결과는 디스크에 기록하지 않으며 앱을 재시작하면 작업 상태도 사라집니다. 완료 작업은 10분·최대 20개 한도 내에서만 유지합니다. 수신·송신이 완료된 파일 메타데이터는 대기 목록에서 제거합니다. 과거 작업 목록과 전송 기록 조회 도구는 제공하지 않습니다. 이전 버전의 jobs 파일은 읽지 않습니다.

`list_shared_files`는 기존 수신함 항목을 ID로 제공합니다. 저장 수락 뒤에도 해당 ID와 메타데이터를 보존하므로 저장된 파일도 읽을 수 있습니다. 사용자가 임시 파일을 취소하면 항목과 파일이 함께 제거되어 읽을 수 없고, 저장 폴더에서 파일을 직접 삭제한 경우에는 `unavailable` 상태와 읽기 불가 정보가 반환됩니다. 다른 파일 시스템 경로를 읽는 도구는 없습니다.

취소는 항목 사이에서 반영됩니다. 이미 진행 중인 파일 이동·복사는 완료될 수 있으며 완료된 저장이나 송신 대기열 추가는 되돌리지 않습니다. 대기열에 들어간 파일을 철회하려면 `cancel_outbox_files`를 사용합니다. 작업 성공은 휴대전화의 실제 수신 완료를 뜻하지 않습니다. 휴대전화가 **받기**를 실행한 뒤 해당 항목이 `list_outbox`에서 사라졌는지 확인합니다.

파일은 절대 경로의 일반 파일만 허용하며 심볼릭 링크는 제외합니다. 한 작업은 파일 경로 16개 또는 항목 ID 100개까지 받습니다. 실제 파일 크기 제한은 기존과 같은 20 GiB입니다. 임의 저장 폴더 지정은 허용하지 않고 GUI 설정을 사용합니다. 임시 파일 삭제 도구는 사용자가 명시한 항목에만 호출합니다.

`receive_text_file`은 로컬 경로나 ChatGPT 다운로드 링크를 열지 않고 MCP 인자로 받은 UTF-8 본문을 저장합니다. 본문은 최대 128 KiB이며, SHA-256을 계산한 뒤 디스크에 기록된 임시 파일의 해시와 비교합니다. 파일명은 경로로 사용하지 않고 수신 항목의 표시 이름으로만 전달하며, 저장 시 기존 파일명 충돌은 `(1)`, `(2)`를 붙여 보존합니다. 같은 내용의 중복 수신은 기존 SHA-256 중복 제거 규칙을 따릅니다. PDF·이미지 등 바이너리는 현재 이 도구에서 받지 않습니다.

Finder 공유 확장은 최대 16개 파일(각 20 GiB까지)을 App Group의 임시 전달함으로 복사하고 SHA-256 manifest를 마지막에 기록합니다. 앱은 실행될 때 이 전달함을 기존 수신함으로 가져오며 원본 파일은 건드리지 않습니다. LinkDeck MCP의 파일 읽기는 SRT·Markdown·TXT·JSON 등 텍스트만 지원하고 파일 경로 대신 최대 32 KiB의 UTF-8 청크 내용을 반환합니다. 잘못된 UTF-8과 PDF·이미지 등의 텍스트 읽기는 오류입니다.

## 내부 작업 API

기존 [HTTP API](api.md)에 다음 GUI 작업 경로를 추가했습니다. 같은 TLS·Bearer 인증이 필요하며 **루프백 연결에서만** 사용할 수 있습니다. LinkDeck과 직접 통신하는 전송 방식은 여전히 MCP stdio입니다.

- `POST /v1/jobs`: JSON `operation`과 `itemIDs`·`filePaths`·`text`·`filename`·`content`로 작업 생성
- `GET /v1/jobs/{id}`: 실행 중 작업의 진행 상태
- `POST /v1/jobs/{id}/cancel`: 나머지 항목 취소 요청
- `GET /v1/items/{id}`: 기존 항목의 메타데이터 조회

작업 `operation`은 `receive`, `receiveAll`, `cancelInbox`, `cancelOutbox`, `sendText`, `sendFiles`, `importFiles`, `receiveTextFile`입니다. 이벤트에는 `outbox.cancelled`도 포함됩니다.

## 검증

```sh
python3 -u script/verify_mcp.py --bundle ShareStackMac.app
```

실제 번들 실행 파일을 자식 프로세스로 띄워 JSON-RPC 초기화, 도구 목록, GUI 자동 실행, 기존 파일 전송 및 `receive_text_file`, shared-file MCP 목록·정보·UTF-8 청크 읽기를 확인합니다. Finder 메뉴 노출은 macOS LaunchServices 등록 및 Finder UI 확인이 별도로 필요하며 자동 MCP 검증만으로 확인되지 않습니다. 검증은 고유한 이름의 합성 파일만 만들고 원본 파일을 보존합니다.

MCP stdout에는 JSON-RPC만 출력하고 로그는 stderr로 보냅니다. EOF로 MCP 프로세스를 종료해도 GUI는 유지됩니다. JSON 안내 파일에는 경로, 토큰, 키 또는 인증 정보가 들어가지 않습니다.
