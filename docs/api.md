# Share Stack API

맥 앱을 실행하면 HTTPS 포트 `8765`에서 사용할 수 있습니다. 같은 맥의 `127.0.0.1`, 사설 IPv4, Tailscale IPv4를 지원합니다.

모든 요청에는 `Authorization: Bearer <토큰>`이 필요합니다. 메뉴의 **연결 정보**에서 토큰과 인증 지문을 복사합니다. 기존 기기 연결 토큰을 함께 사용하므로 이 토큰에는 파일 조회·저장·삭제 권한이 있습니다.

## 임시 보관 위치

맥 앱의 **설정 → 임시 보관 폴더 → 변경…**에서 위치를 고릅니다. 선택한 위치에 전용 `ShareStack Inbox` 하위 폴더를 만들며, 같은 이름의 폴더가 있으면 번호를 붙입니다. 기존 대기 파일을 복사하고 SHA-256을 확인한 뒤 설정을 전환합니다. 복사나 설정 저장이 실패하면 기존 위치를 유지합니다. `GET /v1/status`의 `receiptSettings.inboxFolderPath`는 실제 임시 보관 경로입니다.

보관함에서 삭제·취소하면 해당 임시 파일도 삭제됩니다. 저장 수락 시에는 기존 `folderPath`로 옮깁니다. Finder 확장의 전달 대기 영역과 전송 중 작업 파일은 기존 앱 관리 공간을 계속 사용합니다. 외장 드라이브를 선택했다면 드라이브가 연결되어 있어야 합니다.

## 기능

| 메서드 | 경로 | 동작 |
|---|---|---|
| GET | `/v1/health` | 서버 응답 확인 |
| GET | `/v1/status` | 주소, 수신 설정, 보관함·송신 대기 개수 |
| GET | `/v1/inbox` | 임시 보관 중인 파일 목록 |
| GET | `/v1/shared-files?limit=50&offset=0` | 수신·저장된 ShareStack 파일 목록과 Finder 가져오기 대기 수 |
| GET | `/v1/shared-files/{id}` | 읽기 가능 여부, 크기, MIME, SHA-256 등 파일 정보 |
| GET | `/v1/shared-files/{id}/content?offset=0&limit=4096` | ID로 허용된 UTF-8 텍스트의 실제 내용 청크 (최대 32 KiB) |
| POST | `/v1/inbox/{id}/accept` | 한 파일을 설정된 폴더로 이동 |
| POST | `/v1/inbox/accept-all` | 요청 시점의 모든 대기 파일 저장 |
| DELETE | `/v1/inbox/{id}` | 임시 파일과 보관함 항목 삭제 |
| GET | `/v1/events` | 수신·저장·취소 이벤트 조회 |
| POST | `/v1/outbox/text` | 텍스트를 휴대전화 송신 대기열에 추가 |
| POST | `/v1/outbox/files` | 파일을 휴대전화 송신 대기열에 추가 |
| GET | `/v1/pending` | 휴대전화 송신 대기열과 아직 전달하지 않은 AI 생성 파일 조회 |
| GET | `/v1/items/{id}/content` | 파일 내용. 기존 bytes Range 지원 |

수신·취소 요청에는 본문을 보내지 않습니다. 수신 폴더는 맥 앱 설정을 사용하며 API 요청으로 임의 경로를 지정할 수 없습니다. ChatGPT 읽기용 수신 ID는 저장 뒤에도 메타데이터를 유지하며, 파일을 삭제하면 읽기 불가로 반환합니다. 취소는 수신 대기 항목에만 적용됩니다. 같은 이름은 번호를 붙여 저장합니다.

전체 수신 응답은 `{"saved": [...], "failed": [{"id": "...", "error": "..."}]}`입니다. 일부 실패도 HTTP 200이므로 `failed`를 확인해야 합니다. 실패한 파일은 보관함에 남습니다. API에서 변경한 결과는 앱 보관함과 메뉴바 배지에도 반영됩니다.

텍스트 요청은 `Content-Type: application/json`과 `{"text":"내용"}`을 보냅니다. 본문 제한은 1 MiB이며 빈 문자열은 허용하지 않습니다. 성공하면 생성된 항목과 HTTP 201을 반환합니다. 휴대전화가 **받기**를 실행해야 실제 전송됩니다.

파일 요청은 원본 바이트를 본문으로 보내고 다음 헤더를 지정합니다. 최대 크기는 20 GiB입니다. 파일을 보내기 전에 SHA-256을 계산하며 서버도 검증합니다.

- `Content-Length`: 파일 바이트 수
- `X-Item-Name`: UTF-8 파일명을 base64url로 인코딩한 값
- `X-Item-Mime`: MIME 형식을 같은 방식으로 인코딩한 값
- `X-Item-SHA256`: 소문자 64자리 SHA-256

기존 휴대전화→맥 전송 API인 `/v1/items`, `/v1/uploads`, `/v1/uploads/{sha256}`, `/v1/uploads/{sha256}/finish`, `/v1/items/{id}/ack`는 유지합니다. 송신 대기열에 넣을 때는 `/v1/outbox/*`를 사용합니다. `/v1/items/{id}/ack`는 이미 제거된 ID에도 200을 반환합니다(멱등).

## 인증 지문을 확인하는 호출 예

Python 표준 라이브러리만 사용합니다. 토큰은 TLS 연결 뒤 인증서 지문을 확인한 후 전송합니다. `HOST`에는 `127.0.0.1`, 맥의 Wi-Fi IP 또는 Tailscale IP를 넣습니다.

```python
import getpass
import hashlib
import hmac
import http.client
import json
import re
import ssl

HOST = "127.0.0.1"
PIN = input("맥 앱의 인증 지문: ").strip().lower()
TOKEN = getpass.getpass("맥 앱의 토큰: ").strip()
if not re.fullmatch(r"[0-9a-f]{64}", PIN):
    raise ValueError("인증 지문은 소문자 64자리 SHA-256입니다")

def request(method, path, payload=None):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    connection = http.client.HTTPSConnection(HOST, 8765, context=context, timeout=120)
    try:
        connection.connect()
        actual = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest()
        if not hmac.compare_digest(actual, PIN):
            raise RuntimeError("인증서 지문이 다릅니다")
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        connection.request(method, path, body=body, headers={
            "Authorization": "Bearer " + TOKEN,
            "Content-Type": "application/json",
        })
        response = connection.getresponse()
        result = json.loads(response.read())
        if response.status >= 400:
            raise RuntimeError(result)
        return result
    finally:
        connection.close()

print(request("GET", "/v1/inbox"))
```

같은 `request` 함수로 개별 수신은 `request("POST", "/v1/inbox/파일ID/accept")`, 전체 수신은 `request("POST", "/v1/inbox/accept-all")`, 취소는 `request("DELETE", "/v1/inbox/파일ID")`를 호출합니다. 텍스트 보내기는 `request("POST", "/v1/outbox/text", {"text": "내용"})`입니다.

## 이벤트

`GET /v1/events` 응답:

```json
{
  "streamID": "앱 실행마다 달라지는 ID",
  "nextCursor": 2,
  "hasMore": false,
  "events": [
    {"sequence": 1, "type": "file.received", "itemID": "파일ID", "createdAt": 814060800},
    {"sequence": 2, "type": "file.saved", "itemID": "파일ID", "createdAt": 814060801}
  ]
}
```

다음 조회는 `/v1/events?after=2&streamID=응답의ID`로 요청합니다. `hasMore`가 true면 다음 커서로 계속 조회합니다. false면 원하는 간격으로 재조회합니다. 이벤트 종류는 `file.received`, `file.saved`, `file.cancelled`, `file.save_failed`, `outbox.cancelled`이며 실패 이벤트에는 `error`가 포함됩니다. UI 조작과 API 조작 모두 기록합니다.

이벤트는 메모리에 최근 200개를 유지하고 한 번에 최대 100개 반환합니다. 앱 재실행 또는 오래된 커서는 HTTP 409입니다. 이때 보관함을 다시 읽고 커서 없이 이벤트 조회를 시작합니다. 과거 전송 기록 조회는 제공하지 않습니다. 푸시 알림이나 웹훅은 제공하지 않습니다.

항목과 이벤트의 `createdAt`은 2001-01-01 00:00:00 UTC 이후 초입니다. Unix 초로 변환하려면 `978307200`을 더합니다.

## 오류

오류 응답은 `{"error":"설명"}`입니다. HTTP 400은 입력 오류, 401은 토큰 불일치, 404는 없는 항목·경로, 409는 상태 충돌·저장 실패·이벤트 커서 만료입니다. 보관함 수신과 취소에는 목록에서 받은 UUID를 사용합니다.

[OpenAPI 명세](openapi.yaml). LinkDeck용 MCP stdio 도구 및 GUI 작업 API는 [LinkDeck 연결 문서](linkdeck.md)를 참고하세요. 이벤트에는 송신 대기 취소를 나타내는 `outbox.cancelled`도 포함됩니다.

## 휴대폰의 파일별 AI 읽기 동기화

`POST /v1/phone-ai-read`는 기존 **휴대폰 짝 토큰**으로만 사용할 수 있습니다. AI용 토큰에는 접근을 허용하지 않으며 LinkDeck 도구에도 노출하지 않습니다. JSON 본문은 최대 4 KiB입니다.

```json
{"id":"휴대폰이 파일별로 생성한 UUID","revision":1,"allowed":true,"sourceID":"수신 완료한 Mac 항목 UUID","sha256":"해당 파일의 SHA-256"}
```

휴대폰은 기존 이어받기 업로드가 완료된 후 이 요청을 보냅니다. `sourceID`는 `/v1/uploads/{sha256}/finish` 응답의 `id`이며, 동일한 내용이 이미 수신됐어도 finish를 다시 호출할 수 있습니다. 허용 요청은 수신 항목과 SHA-256이 일치해야 합니다. Mac은 취소 유예와 내부 사본 검증이 끝난 후에만 허용하며 응답은 `{"id":"...","revision":1,"allowed":true,"ready":true}`입니다. 전체 AI 읽기가 꺼져 있으면 `ready`는 false입니다. 일반 업로드에는 자동 허용을 적용하지 않습니다.

해제는 같은 `id`와 더 큰 `revision`으로 `{"id":"...","revision":2,"allowed":false}`를 보냅니다. 파일을 삭제하지 않고 이후 목록·정보·본문 접근을 차단합니다. 허용보다 해제가 먼저 도착해도 기록하며, 재시작 후에도 작은 순번의 요청은 최신 상태를 반환할 뿐 권한을 바꾸지 않습니다. 같은 순번을 다른 선택에 재사용하거나 같은 ID를 다른 파일에 재연결하면 거부합니다.

Mac에서 직접 해제하면 진행 중인 이전 휴대폰 준비와 같은 순번의 재시도도 차단합니다. 다시 허용하려면 휴대폰에서 해제 후 재체크해 새 순번으로 요청합니다. 휴대폰은 자신의 최신 순번·선택과 일치하는 응답만 반영하고, 허용 시에는 `ready:true`까지 확인해야 합니다. 이전 버전 Mac은 이 경로를 지원하지 않으므로 양쪽 앱을 함께 갱신해야 합니다.

휴대폰 대기 목록은 일반 송신 항목과 AI 생성 보관함 파일을 함께 반환합니다. AI 생성 파일의 ACK(`/v1/items/{id}/ack`)와 송신 취소는 전달 대기만 해제하고 Mac 보관함 원본은 유지합니다. AI 생성 일반 수신 항목의 `phoneDeliveryPending`은 선택적 불리언이며, true는 휴대폰 전달 대기, false는 전달 완료 또는 취소입니다. 실제 파일이 없어지면 목록에서 제외하며, 휴대폰 원본에 연결된 AI 사본은 송신 대상으로 취급하지 않습니다. 수신 완료 상태는 디스크에 저장하므로 앱 재시작 후 반복 수신하지 않습니다.


## 작업공간 전용 API와 기존 경로 차단

작업공간 API는 루프백의 별도 AI bearer 토큰만 허용합니다. 전화 토큰은 거부됩니다. `POST /v1/workspace-session`에 `{"label":"클라이언트 이름"}`을 보내면 서버가 pending 연결의 `id`, `credential`을 발급합니다. 이 호출은 권한을 부여하지 않습니다. 사용자가 GUI에서 그 연결을 작업공간에 승인한 뒤에만, 이후 요청의 `X-Workspace-Session: <credential>`로 접근할 수 있습니다. 자격증명은 로그에 남기지 않으며 앱 재시작 시 만료됩니다.

| 메서드 | 경로 | 동작 |
|---|---|---|
| GET | `/v1/workspaces` | 승인된 작업공간 요약 |
| GET | `/v1/workspaces/{workspaceId}/entries?relativePath=&cursor=0&limit=50` | 디렉터리 목록 |
| GET | `/v1/workspaces/{workspaceId}/files/{fileId}` | 파일 정보 |
| GET | `/v1/workspaces/{workspaceId}/files/{fileId}/content?offset=0&limit=4096` | UTF-8 본문 청크 |
| GET | `/v1/workspaces/{workspaceId}/changes` | baseline 대비 diff |
| POST | `/v1/workspaces/{workspaceId}/create` | `relativePath`, `content`, `requestKey` |
| POST | `/v1/workspaces/{workspaceId}/patch` | `fileId`, `expectedHash`, `patch`, `requestKey` |

읽기 전용·다른 연결·비공개·전화 인증·전체 AI 읽기 중지는 `403 PERMISSION_DENIED`, 버전/요청 키 충돌은 `409 CONFLICT`, 상한 초과는 `413 LIMIT_EXCEEDED`입니다. 원본 절대 경로를 받거나 반환하지 않습니다. 모드 변경·원본 반영·명령 실행 API는 없습니다.

보호된 관리 복사본을 기존 API로 읽는 우회를 막기 위해 `/v1/jobs`의 절대 경로 기반 `sendFiles`와 `importFiles`는 모든 HTTP 호출자에게 403을 반환합니다. Finder 공유, GUI 파일 선택, 바이트 본문 업로드(`/v1/items`, `/v1/outbox/files`), Galaxy 조각 송수신, 텍스트 교환은 유지합니다.

변경사항 조회는 `cursor`(기본 `0:0`)와 `limit`(기본20, 최대100)으로 페이지를 이어갑니다. `diffOffset` 순서로 같은 파일의 `diff`를 합치고 `nextCursor`가 없어질 때까지 조회합니다. diff 청크는 256 KiB, 페이지 전체 diff는 1 MiB로 제한하며 UTF-8 문자를 나누지 않습니다. GUI는 첫 페이지를 미리보기하고 추가 페이지 존재를 표시합니다. 격리 편집의 입력과 결과 파일은 각각 128 KiB/1 MiB 상한이며, 더 큰 파일(최대100 MiB)은 읽기 전용 분석만 지원합니다.
