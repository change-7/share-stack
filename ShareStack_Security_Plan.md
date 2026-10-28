# ShareStack macOS 보안 개선 설계안

작성일: 2026-10-28  
범위: `macos/ShareStackMac`의 macOS 앱, Finder Share Extension, LinkDeck MCP와 같은 앱이 제공하는 로컬 HTTP 인터페이스. Android 구현, 외부 서비스, 배포·서명 절차는 대상에서 제외한다.  
상태: 설계 제안. 구현하거나 설정을 변경하지 않았다.

기준 구현: `change-7/share-stack`의 `70524cb` (2026-10-19). 후속 작업 트리에는 설계 일부가 반영됐을 수 있으므로, 이 문서는 현재 구현의 완료 상태를 보증하지 않는다.

## 목표와 적용 원칙

기본 상태에서 AI 클라이언트가 파일 목록이나 내용을 읽지 못하게 한다. 사용자가 ShareStack UI에서 파일별로 읽기를 허용한 경우에만 해당 MCP 세션이 허용된 파일을 읽는다. Finder 공유, 수신함, 저장 수락, Galaxy와의 기존 송수신은 현재 동작을 유지한다. 파일 저장·전송·삭제는 읽기 허용과 별도의 동작이며, MCP 도구 설명의 경고 문구만으로 사용자 승인을 대신하지 않는다.

우선 적용 순서는 **세션·파일 권한 경계**, **파일 경로 입력 제거**, **저장 내용과 허용 시점의 동일성**, **자원 상한과 회수 가능성**이다. 이 순서는 우선순위 제안이며 취약점 점수는 아니다.

## 권한 모델

### 주체별 허용 범위

| 주체 | 기본 허용 | 별도 사용자 동작이 필요한 일 |
|---|---|---|
| ShareStack UI를 조작하는 사용자 | 현재 수신함·저장 설정과 Finder 수신을 관리 | 기존 UI가 요구하는 저장·취소 확인 |
| 페어링된 휴대폰 | 해당 전송 프로토콜의 파일 업로드, 기기로의 송신 대기 파일 조회·수신 확인 | AI 파일 열람, 다른 기기 파일 관리, 저장·삭제 정책 변경 |
| LinkDeck/AI MCP 세션 | 상태 확인에 필요한 최소 정보 | 파일 목록·메타데이터·내용 읽기: 파일별 UI 허용. 전송·저장·삭제: 각 작업별 UI 승인 |
| Share Extension | 사용자가 Finder 공유 메뉴에서 선택한 항목을 App Group 수신 배치로 복사 | 앱 전체 파일 접근, 승인 없이 파일 내용을 외부로 전달 |

네트워크 주소만으로 주체를 판별하지 않는다. 현재 `/v1/jobs`가 loopback 주소를 확인하더라도 그 주소는 “LinkDeck 프로세스”의 증명이 아니다. 앱과 LinkDeck MCP stdio 세션 사이에 신뢰할 수 있는 세션 식별자를 만들고, HTTP 요청은 그 세션의 권한으로 검증한다. 클라이언트가 `caller=ui` 같은 값을 보내는 방식은 권한 증거로 인정하지 않는다. OS audit token 기반 XPC 중개를 검토할 수 있지만 현재 ad-hoc 서명 구성을 유지하는 동안 안정적인 서명 주체 식별이 가능한지 먼저 확인해야 한다. 확인 전에는 XPC를 이미 보장된 신원으로 취급하지 않는다.

### 파일별 AI 읽기 허용

`TransferItem.isShared`는 현재 공유 파일 목록에 나타낼 분류로 계속 사용하되, AI 동의로 재해석하지 않는다. 별도의 AI 접근 허용 레코드를 둔다. 기본값은 허용 없음이며, 기존 수신함 파일이나 저장 파일에도 자동으로 허용을 부여하지 않는다.

레코드에 포함할 최소 값:

- `fileID`, 승인 당시 `contentVersion`(SHA-256과 크기를 묶은 값)
- 허용한 세션 식별자, 허용 작업 집합(초기에는 `list`, `read`)
- 생성·만료 시각, 폐기 시각, 권한 세대 번호
- 저장 원본 상태가 바뀌었는지 판단할 수 있는 내부 참조

ShareStack UI의 파일 행에서 “AI가 읽도록 허용”을 명시적으로 누르게 한다. UI에는 파일명, 읽기 허용 상태, 만료와 폐기 동작을 표시한다. 기본은 허용 안 함이고, 전체 수신함 일괄 허용을 기본 선택으로 두지 않는다. LinkDeck의 확인 창이 보이는지, 확인 로그가 남는지, 파일 내용이 클라우드에 얼마나 보존되는지는 현재 확인되지 않았으므로 제품 자체의 게이트를 필수로 둔다.

목록·정보·읽기 API뿐 아니라 `list_inbox`, `get_item`, 이벤트, 상태와 기존 content 라우트 등 별칭 경로에도 같은 검사 함수를 적용한다. 미허용 파일 ID와 없는 ID는 동일한 `NOT_FOUND` 응답으로 감춰 존재 여부를 노출하지 않는다. 전체 경로, 저장 폴더 경로, 승인되지 않은 파일명·개수·확장자는 AI 응답에 포함하지 않는다.

## 파일 읽기와 내용 동일성

### 단일 권한 검사점

`TransferStore.sharedFiles`, `sharedFileInfo`, `readSharedFile`를 호출하는 모든 경로가 동일한 AI 권한 검사기를 통과하도록 한다. MCP 도구와 HTTP `/v1/shared-files`가 따로 권한을 구현하지 않게 한다. 현재 `routeSharedFiles`는 공통 Bearer 인증은 거치지만 loopback 제한은 없으며, pending과 saved 항목을 모두 노출한다. 네트워크 접근 제어만 덧붙이지 말고 파일별 세션 허용 검사를 이 경로와 우회 가능한 legacy 경로에 함께 적용한다.

기존 `/v1/items/{id}/content`는 pending 파일의 원본 바이트를 돌려주는 경로다. AI 주체가 이 경로에 접근하지 못하도록 audience/operation 정책을 적용하거나, 파일별 grant가 동일하게 요구되도록 한다. 휴대폰 수신에 필요한 기존 동작은 별도 휴대폰 권한으로 계속 작동해야 한다.

### 허용된 바이트의 고정

현재 읽기 구현은 허용 파일 URL을 찾은 뒤 잠금을 풀고 열며, 파일이 일반 파일이고 저장된 크기와 현재 크기가 같은지 확인한다. 같은 크기로 바뀐 내용은 기존 저장 해시와 대조되지 않는다. 다음 방식으로 교체한다.

1. 사용자가 읽기를 허용할 때 현재 파일을 열어 regular-file 여부, 크기, SHA-256을 확인한다.
2. 파일 ID와 내용을 식별하는 `contentVersion`을 grant에 묶는다.
3. 앱 관리 저장 영역에 승인 대상의 불변 스냅샷을 원자적으로 만든다. 초기에는 설정 가능한 작은 상한(예: 텍스트 8 MiB)을 두고, 상한을 넘는 파일은 이유와 실제 크기를 알려주며 허용하지 않는다. 이 상한은 구현 전에 제품 상수로 확정한다.
4. 각 읽기 요청은 grant의 세션·만료·폐기 상태와 `contentVersion`을 확인하고 스냅샷에서 offset/limit 구간을 읽는다. UTF-8 경계 정렬과 기존 읽기 응답 형식은 보존한다.
5. 취소·삭제·grant 철회 시 이후 요청은 즉시 거부하고 스냅샷을 제거한다. 이미 응답한 바이트나 모델 대화에 전달된 내용까지 회수할 수 있다고 표시하지 않는다.

기존 외부 임시 보관 위치의 파일은 승인 당시 경로 문자열에 계속 의존하지 않는다. 같은 파일이 교체되거나 저장 경로가 변경되었는데 내용을 보장할 수 없으면 기존 허용을 폐기하고 다시 허용받는다. 파일 읽기에 `O_NOFOLLOW`와 `fstat` 검사를 유지하되, 최종 요소만 검사하는 것에 그치지 말고 신뢰할 디렉터리 경계에서의 경로 교체도 방어한다. 파일 복사 도중 원본 크기가 늘면 복사하면서 상한을 검사하고 초과 즉시 중단·부분 파일 삭제한다.

스냅샷은 AI 읽기 전용이다. 이 설계가 같은 사용자 권한으로 실행되는 악성 로컬 프로세스나 이미 유출된 데이터를 차단한다고 주장하지 않는다. 읽은 뒤 ShareStack 파일이 삭제되면 읽기 권한과 스냅샷은 폐기한다. 저장 파일 삭제가 실패해 원본이 남더라도 grant는 되살리지 않으며 UI에 삭제 실패와 재시도 방법을 알린다.

## MCP 및 HTTP API 제안

기존 읽기 도구의 이름을 유지해 LinkDeck의 도구 새로 고침 후 호환되도록 한다. 각 도구의 서버 구현은 UI 승인 상태를 검증한다.

```text
list_shared_files({ offset, limit })
  -> { items: [{ id, name, size, extension, receivedAt, state,
                contentVersion }], nextOffset }
     items에는 현재 MCP 세션에 list 허용이 있는 파일만 포함

get_shared_file_info({ id })
  -> { id, name, size, mimeType, sha256, contentVersion,
       readable, grantExpiresAt }
     readable=true는 현재 세션에 유효한 grant가 있을 때만 반환

read_shared_file({ id, contentVersion, offset, limit })
  -> { content, startOffset, nextOffset, hasMore, contentVersion }
     UTF-8 코드포인트 중간을 자르지 않고 승인된 스냅샷에서 읽음

get_ai_access_status()
  -> { enabled, sessionExpiresAt }
     승인되지 않은 파일 정보·전체 수신함 크기는 반환하지 않음

request_file_action({ operation, fileIds, contentVersions, requestKey })
  -> { requestId, status: "pending", expiresAt }

apply_file_action({ requestId, actionGrant, requestKey })
  -> { jobId, status }
     UI에서 승인한 정확한 작업·파일·버전·세션에만 유효한 단회 grant 필요
```

`request_file_action`은 작업을 실행하지 않는다. 사용자가 앱 UI에서 파일명과 send/save/delete 작업을 확인하고 승인해야 한다. 승인은 짧은 만료와 단회 사용을 가지며, 서버가 발급한 난수 핸들로 정확한 파일 ID와 `contentVersion`, 작업 종류, 세션에 묶는다. MCP가 자기 요청을 승인하는 API는 만들지 않는다. 같은 `requestKey` 재전송은 결과를 중복 실행하지 않는다.

기존 MCP의 `send_files(paths)`와 `add_inbox_files(paths)`는 임의 경로를 받으므로 AI MCP에 노출하지 않는다. GUI의 파일 선택기는 계속 사용한다. MCP에서는 수신함 ID와 승인된 작업 요청으로 대체한다. 기존 `receive_text_file`은 작은 텍스트 입력을 수신함에 만드는 기능으로 유지할 수 있지만, 저장 후 읽기 grant를 자동 생성하지 않는다. 입력은 비신뢰 데이터로 취급한다. `receive_all`은 요청 순간의 대상 파일 ID를 고정하고, 승인 화면에서 실제 대상을 확인한다. 현재처럼 큐 실행 시점의 수신함 전체를 새로 선택하지 않는다.

도구 설명의 `readOnlyHint`, `destructiveHint`는 MCP 클라이언트 안내용 메타데이터일 뿐 서버 권한검사가 아니다. 서버의 handler/router 경계에서 검사를 강제한다. 응답에 실제 파일 텍스트가 포함될 때는 작은 고정 limit을 두고 다음 offset을 반환한다. 목록은 승인 파일만 페이지네이션하며, 큰 파일 전체를 한 번에 메모리에 올리지 않는다.

## 네트워크·인증 변경

현재 MCP stdio와 GUI HTTP 브리지가 같은 Keychain Bearer 토큰을 사용하며, 서버는 Bonjour를 게시하고 네트워크 인터페이스에 listener를 연다. `/v1/shared-files`, `/v1/items`, 제어 경로는 `/v1/jobs`의 loopback 검사와 범위가 다르다. 이 구성에서는 “loopback 전용이면 MCP 전용”이라는 가정이 성립하지 않는다.

최소 변경안은 동일 HTTP 서버의 모든 라우트에 호출자 audience와 작업 범위를 검사하고, LinkDeck MCP bridge에만 AI 세션 자격을 발급하는 것이다. 기존 휴대폰 Bearer를 AI 세션으로 취급하지 않는다. 휴대폰 자격 증명과 MCP 자격 증명을 분리하고, 설정 UI에서 기기별 페어링 해제·회전을 제공한다. MCP 세션을 닫거나 사용자가 AI 접근을 끄면 세션 grant를 폐기한다. 기존 설치 토큰을 조용히 새 권한으로 승격하지 않는다.

TLS 인증서 pin, 인증 토큰 비교, HTTP body 및 연결 상한은 보존한다. 다만 `Data` 전체 할당 뒤 크기를 검사하는 응답 제한과 현재 누적 업로드 제한이 부족한 지점은 별도 자원 정책으로 보완한다. Firewall, VPN ACL, 프록시와 실제 listener 주소는 이 조사에서 확인되지 않았으므로 네트워크 레이어를 제품 권한의 대체재로 가정하지 않는다.

## 경로 입력과 파일시스템 안전

### MCP 경로 입력 제거

`TransferJobs.Request.sendFiles`와 `importFiles`는 절대 경로 배열을 받는다. 검증은 절대경로·NUL·개수 중심이며 사용자가 직접 GUI에서 고른 파일이라는 증명이 없다. `TransferStore.enqueueFile`과 `importReceivedFile`은 경로 복사 후 일부 파일 검사를 한다. AI MCP 경계에서는 해당 경로 도구 호출을 차단한다. GUI 열기 패널 및 Finder Share Extension 경로는 명시적 사용자 선택 흐름으로 그대로 둔다.

### 안전한 복사와 충돌

- 파일명은 표시용 메타데이터일 뿐 대상 경로로 직접 결합하지 않는다. 현재 UUID 저장 파일과 basename 정리는 유지한다.
- 파일·부모 디렉터리는 심볼릭 링크를 따라가지 않으며, 저장 디렉터리는 실제 경로와 파일시스템 경계를 확인한다.
- 목적지 파일은 임시 파일 `O_EXCL` 생성, 제한된 권한, 복사 중 byte cap, SHA-256, `fsync`, 원자적 rename 순서로 확정한다.
- 동일 표시 파일명은 UUID로 저장하고 UI에서 충돌 회피 이름을 제공한다. 임의 기존 파일 덮어쓰기는 허용하지 않는다.
- 하드링크를 허용할지 정책을 명시한다. 허용하지 않으면 `st_nlink`를 검사하거나 파일을 앱 영역에 복사해 이후 원본 변경과 분리한다.
- 확장자와 MIME은 분류·화면 표시용이다. 확장자만 믿어 실행하거나 안전하다고 판정하지 않는다. 압축파일 자동 해제, 스크립트 자동실행, 콘텐츠의 지시문 실행은 추가하지 않는다.

## 자원 제한 및 실패 처리

현재 파일별 상한과 동시 연결 상한이 있어도 누적 수신함 크기, 대기 job 수, 공유 확장 manifest 크기에는 별도 상한이 보이지 않는다. 다음 제한은 코드 변경 전에 기존 정상 Galaxy 전송의 파일 크기 사용을 확인한 뒤 값 확정이 필요하다.

1. 수신함 최대 파일 수와 누적 byte 수, 진행 중 upload 총 예약 byte 수.
2. MCP/휴대폰 주체별 동시 job 수와 요청 빈도, job queue 최대 길이.
3. 파일별 제한 외에 Share Extension 파일 개수·복사 총량·manifest byte 수.
4. 복사 중 소스 변경 감지와 상한 초과 즉시 중단. 실패한 임시 파일은 정리하되 원본은 건드리지 않는다.
5. 스테일 upload 세션 정리는 초기 실행 시 한 번으로 끝나지 않도록 주기 정책을 명시한다. 이미 수신된 사용자 파일을 임의 TTL로 지우지 않는다.
6. 디스크 여유 공간이 부족하면 목적지 확정 전에 실패하고 명확한 오류를 반환한다.

업로드 실패, 해시 불일치, 저장 폴더 이동 실패는 성공으로 표시하지 않는다. 저장소 이동이 여러 파일에 걸쳐 실패할 때 현재처럼 복사본이 남을 수 있는 경우에는 남은 ID와 복구·재시도 상태를 UI에 표시한다. 삭제·취소 중 한 파일이 실패하면 성공한 파일과 실패한 파일을 각각 보고하고, AI grant는 실패한 파일에도 다시 열지 않는다.

## 사용자 파일과 프롬프트 주입

공유한 문서의 텍스트는 악의적 지시문을 포함할 수 있는 데이터다. ChatGPT가 내용을 읽도록 허용해도 해당 텍스트에 적힌 명령을 ShareStack 도구 권한으로 승격하지 않는다. 파일 내용은 도구 호출 승인, 경로 선택, 삭제 승인에 사용할 수 없다. 각 MCP 동작의 서버 권한 검사는 모델의 파일 해석이나 시스템 프롬프트와 독립적으로 동작한다. PDF·이미지 OCR 같은 파서는 별도 기능으로 추가하지 않으며, 초기 읽기 범위는 이미 지원되는 텍스트 파일에 한정한다.

## 감사 기록과 사용자 피드백

초기 로그에는 시각, 불투명 세션 ID, 불투명 파일 ID, 작업 종류, 허용/거부, 오류 코드, grant ID만 둔다. 파일 본문, 토큰, 전체 로컬 경로는 기록하지 않는다. 기록 크기와 보존 기간을 제한하고 앱 설정에서 사용자가 확인·삭제 가능하도록 한다. 기존 job error가 경로를 포함할 수 있으므로 외부 MCP 오류에는 안정적인 오류 코드와 짧은 사용자용 설명만 반환한다. 외부 전송이나 원격 telemetry는 추가하지 않는다.

UI에는 읽기 허용·만료·철회·현재 MCP 연결 상태와 AI가 읽을 수 있는 파일 개수를 보여준다. 권한이 없거나 만료된 경우 “읽기 허용 필요”를 명확히 말하고, 이미 삭제되거나 바뀐 파일은 `FILE_UNAVAILABLE` 또는 `CONTENT_CHANGED`로 처리한다. MCP 오류 응답은 경로, 토큰, 파일 내용 일부를 포함하지 않는다.

## 마이그레이션 및 코드 접점

| 위치 | 변경 설계 |
|---|---|
| `Sources/ShareStackMac/TransferStore.swift`의 `TransferItem`, `sharedFiles`, `sharedFileInfo`, `readSharedFile`, `sharedFileURL`, 수신 파일 복사 | 파일 provenance·contentVersion·AI grant 저장, 승인 스냅샷·회수, 하나의 읽기 정책 검사기 |
| `Sources/ShareStackMac/MCPServer.swift` tool 목록·dispatch 및 `TransferJobs.swift` 요청 종류 | 기존 읽기 도구 이름 유지, 임의 경로 MCP 도구 거부/대체, 작업 요청과 상태 조회 추가 |
| `Sources/ShareStackMac/GUIBridge.swift` | LinkDeck MCP 세션 식별·자격 분리, HTTP 브리지 요청에 서버가 검증하는 caller context 전달 |
| `Sources/ShareStackMac/TransferHTTPServer.swift`의 route dispatcher·`routeSharedFiles`·`routeJobs`·legacy content/control routes | 모든 route에 audience와 operation scope 적용, 우회 경로 같은 파일 검사기 통과, 응답 할당 전 상한 |
| `Sources/ShareStackMac/NetworkIdentity.swift` | 휴대폰과 MCP 자격 분리, 세션 만료·기기별 회전/철회. 기존 페어링은 명시적인 호환 절차 제공 |
| `Sources/ShareStackMac/ShareStackMacApp.swift`, `ReceiptViews.swift` | 파일별 읽기 grant 및 작업 승인·철회 UI, 변경 파일 상태 표시 |
| `ShareStackShareExtension/ShareViewController.swift`, `ShareHandoff.swift` | 기존 Finder 수신을 유지하며 copy loop byte cap과 manifest 상한 추가. AI 읽기는 별도 UI 허용이 있을 때만 가능 |

기존 사용자 파일을 삭제·이동하지 않는다. 신규 grant 필드가 없는 기존 데이터는 `deny`로 해석한다. 구버전 클라이언트가 승인되지 않은 기존 동작을 호출하면 경로 API로 fallback하지 말고 명확한 `UPGRADE_REQUIRED` 또는 `PERMISSION_REQUIRED`를 반환한다. Finder App Group 포맷은 버전 필드를 추가할 때 기존 manifest를 읽을 수 있어야 한다. 저장 설정과 기존 수신함/송신함 데이터는 마이그레이션에서 보존한다.

## 구현 순서와 완료 기준

### 1단계: 권한 기본 거부 및 라우트 일괄 적용

- AI와 휴대폰 caller context 분리, 세션 식별 및 만료.
- 파일별 목록·정보·읽기 grant와 UI 허용/철회.
- legacy shared-content·inbox·event 등 우회 라우트에도 권한 적용.
- 미허용/존재하지 않는 ID를 외부에서 구분할 수 없음.
- 확인 기준: 새 설치와 기존 데이터에서 AI 목록은 0개로 시작하고, 한 파일을 허용하면 그 파일만 목록·정보·내용 읽기에 나타남. 다른 세션·휴대폰 자격·legacy path는 이를 우회하지 못함.

### 2단계: 경로 기반 MCP 작업 제거 및 승인된 변경 작업

- MCP에서 임의 절대경로 입력 차단. GUI open panel과 Finder를 유지.
- 정확한 파일 ID·버전·작업에 묶인 UI 승인, 짧은 만료 단회 action grant.
- receive-all 대상 고정, 중복 요청 idempotency, 실패 부분 결과 명확화.
- 확인 기준: MCP의 임의 경로 전송·가져오기는 실패하며, UI 승인 없는 send/save/delete는 실행되지 않는다. 기존 GUI/Finder/휴대폰 전송은 정상 작동한다.

### 3단계: 승인 내용 고정·회수 및 자원 상한

- 불변 텍스트 snapshot, 크기/해시 결속, UTF-8 chunk 경계, 파일 삭제·변경 시 grant 회수.
- 큐, 누적 저장, 진행 중 업로드, extension manifest, 동시 job 제한.
- 확인 기준: 같은 크기의 내용 교체, 심볼릭 링크, 잘린 UTF-8, 소스 성장, 디스크 부족, 반복 요청에서 읽기 오류 또는 명확한 제한이 반환되고 기존·부분 파일이 잘못 성공 처리되지 않는다.

각 단계가 빌드와 자동화 테스트를 통과한 뒤에만 다음 단계로 진행한다. UI 파일 승인, Finder 수신, Mac↔Galaxy 전송을 실제 macOS 앱에서 회귀 확인한다. 이 문서는 해당 구현이나 테스트가 이미 수행됐다는 뜻이 아니다.

## 테스트 시나리오와 통과 기준

| 시나리오 | 통과 기준 |
|---|---|
| 기본 상태에서 목록·정보·읽기 | 파일 내용·이름·존재 여부가 노출되지 않고 권한 필요 오류 |
| 파일 A만 UI에서 허용 | 현재 세션에만 A가 보이고 읽힘. B·새 세션은 거부 |
| grant 만료·철회·앱 재시작 | 만료·폐기 grant로 새 요청이 거부됨. 재시작 뒤 default-deny가 유지됨 |
| alias 및 legacy content route | 같은 grant 없이 어떤 route에서도 같은 파일을 읽지 못함 |
| 동일 파일명 두 개 | ID가 다르고 기존 파일을 덮지 않으며 올바른 원본으로 읽힘 |
| 같은 크기로 저장 내용 교체 | 기존 contentVersion grant는 거부되고 다시 사용자 허용을 요구 |
| 한글·일본어가 chunk 경계를 가로지름 | 이어 붙인 내용의 UTF-8 byte와 텍스트가 원본과 동일 |
| offset 범위, 빈 파일, 파일 삭제 | 범위 오류는 거부, 빈 파일은 빈 내용 성공, 삭제 파일은 unavailable로 반환 |
| 심볼릭 링크 파일·부모 교체·hardlink 정책 | 허용 경계 밖 대상 읽기·덮어쓰기가 없음 |
| MCP 절대 경로 send/import | 권한 없는 경로는 거부, GUI 선택 동작은 유지 |
| send/save/delete 승인 생략·만료·재전송 | UI 승인 없이는 실행 안 됨, 만료/다른 파일 grant는 거부, 같은 키 재전송은 중복 변경 없음 |
| Share Extension 다중 파일·실패·크기 증가 | 원본 무변경, 완료된 배치만 manifest로 나타나며 실패 임시파일 정리, 전체 cap 적용 |
| Galaxy 기존 업로드·다운로드·ack | 기존 페어링된 동작이 AI 권한 변경으로 깨지지 않음 |
| queue/aggregate cap 초과 | 정확한 제한 오류, 메모리·디스크 누적 없이 요청 중단 |
| 로그 검사 | 본문·Bearer·전체 사용자 경로가 로그와 외부 오류에 나타나지 않음 |

## 별도 명시적 승인이 필요한 향후 고위험 변경

이 설계만으로 Full Disk Access를 요청하거나, 방화벽·VPN·시스템 권한을 변경하거나, 기존 저장 파일을 지우거나, 모든 파일에 AI 읽기를 일괄 허용하지 않는다. 기존 페어링 토큰 전체 회전, 파일 읽기 이력 외부 전송, 수신 파일 자동 삭제 정책도 별도 사용자 요구 없이는 적용하지 않는다. 실제 서비스에서 사용 중인 크기·보존 값에 영향을 주는 quota는 현황 확인 후 사용자에게 동작 변경을 설명하고 적용한다.

## 확인되지 않은 전제

- LinkDeck이 MCP 호출별 사용자 승인을 표시·기록하는지와 ChatGPT 측 파일 본문 보존 정책.
- 실제 배포 앱의 서명, entitlements 적용 상태, Keychain ACL과 macOS 개인정보 권한.
- 실제 listener의 노출 인터페이스, 방화벽·VPN·프록시 정책.
- 사용 중인 파일 크기·누적 수신량에 맞는 구체 quota 값.
- 전원 차단·동시 읽기/삭제·큰 파일·디스크 고갈 상황의 실제 동작.

따라서 제품 내부에서 파일별 권한을 집행하는 설계는 필요하지만, 이를 적용한 뒤에도 ChatGPT 대화에 전달한 파일 내용을 외부에서 회수할 수 있다고 약속하지 않는다.
