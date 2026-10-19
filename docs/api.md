# Share Stack API

맥 앱을 실행하면 HTTPS 포트 `8765`에서 사용할 수 있습니다. 같은 맥의 `127.0.0.1`, 사설 IPv4, Tailscale IPv4를 지원합니다.

모든 요청에는 `Authorization: Bearer <토큰>`이 필요합니다. 메뉴의 **연결 정보**에서 토큰과 인증 지문을 복사합니다. 기존 기기 연결 토큰을 함께 사용하므로 이 토큰에는 파일 조회·저장·삭제 권한이 있습니다.

## 기능

| 메서드 | 경로 | 동작 |
|---|---|---|
| GET | `/v1/health` | 서버 응답 확인 |
| GET | `/v1/status` | 주소, 수신 설정, 보관함·송신 대기 개수 |
| GET | `/v1/inbox` | 임시 보관 중인 파일 목록 |
| POST | `/v1/inbox/{id}/accept` | 한 파일을 설정된 폴더로 이동 |
| POST | `/v1/inbox/accept-all` | 요청 시점의 모든 대기 파일 저장 |
| DELETE | `/v1/inbox/{id}` | 임시 파일과 보관함 항목 삭제 |
| GET | `/v1/history?limit=50&offset=0` | 최근 기록부터 조회. limit 1–100, offset 0 이상 |
| GET | `/v1/events` | 수신·저장·취소 이벤트 조회 |
| POST | `/v1/outbox/text` | 텍스트를 휴대전화 송신 대기열에 추가 |
| POST | `/v1/outbox/files` | 파일을 휴대전화 송신 대기열에 추가 |
| GET | `/v1/pending` | 휴대전화 송신 대기열 조회 |
| GET | `/v1/items/{id}/content` | 파일 내용. 기존 bytes Range 지원 |

수신·취소 요청에는 본문을 보내지 않습니다. 수신 폴더는 맥 앱 설정을 사용하며 API 요청으로 임의 경로를 지정할 수 없습니다. 저장 완료된 항목의 수신 요청은 기존 항목을 반환하며 다시 복사하지 않습니다. 취소는 수신 대기 항목에만 적용됩니다. 같은 이름은 번호를 붙여 저장합니다.

전체 수신 응답은 `{"saved": [...], "failed": [{"id": "...", "error": "..."}]}`입니다. 일부 실패도 HTTP 200이므로 `failed`를 확인해야 합니다. 실패한 파일은 보관함에 남습니다. API에서 변경한 결과는 앱 보관함과 메뉴바 배지에도 반영됩니다.

텍스트 요청은 `Content-Type: application/json`과 `{"text":"내용"}`을 보냅니다. 본문 제한은 1 MiB이며 빈 문자열은 허용하지 않습니다. 성공하면 생성된 항목과 HTTP 201을 반환합니다. 휴대전화가 **받기**를 실행해야 실제 전송됩니다.

파일 요청은 원본 바이트를 본문으로 보내고 다음 헤더를 지정합니다. 최대 크기는 20 GiB입니다. 파일을 보내기 전에 SHA-256을 계산하며 서버도 검증합니다.

- `Content-Length`: 파일 바이트 수
- `X-Item-Name`: UTF-8 파일명을 base64url로 인코딩한 값
- `X-Item-Mime`: MIME 형식을 같은 방식으로 인코딩한 값
- `X-Item-SHA256`: 소문자 64자리 SHA-256

기존 휴대전화→맥 전송 API인 `/v1/items`, `/v1/uploads`, `/v1/uploads/{sha256}`, `/v1/uploads/{sha256}/finish`, `/v1/items/{id}/ack`는 유지합니다. 송신 대기열에 넣을 때는 `/v1/outbox/*`를 사용합니다.

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

다음 조회는 `/v1/events?after=2&streamID=응답의ID`로 요청합니다. `hasMore`가 true면 다음 커서로 계속 조회합니다. false면 원하는 간격으로 재조회합니다. 이벤트 종류는 `file.received`, `file.saved`, `file.cancelled`, `file.save_failed`이며 실패 이벤트에는 `error`가 포함됩니다. UI 조작과 API 조작 모두 기록합니다.

이벤트는 메모리에 최근 200개를 유지하고 한 번에 최대 100개 반환합니다. 앱 재실행 또는 오래된 커서는 HTTP 409입니다. 이때 보관함·기록을 다시 읽고 커서 없이 이벤트 조회를 시작합니다. 푸시 알림이나 웹훅은 제공하지 않습니다.

항목과 이벤트의 `createdAt`은 2001-01-01 00:00:00 UTC 이후 초입니다. Unix 초로 변환하려면 `978307200`을 더합니다.

## 오류

오류 응답은 `{"error":"설명"}`입니다. HTTP 400은 입력 오류, 401은 토큰 불일치, 404는 없는 항목·경로, 409는 상태 충돌·저장 실패·이벤트 커서 만료입니다. 보관함 수신과 취소에는 목록에서 받은 UUID를 사용합니다.

[OpenAPI 명세](openapi.yaml). LinkDeck용 MCP stdio 도구 및 GUI 작업 API는 [LinkDeck 연결 문서](linkdeck.md)를 참고하세요. 이벤트에는 송신 대기 취소를 나타내는 `outbox.cancelled`도 포함됩니다.
