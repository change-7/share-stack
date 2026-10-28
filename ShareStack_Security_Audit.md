# ShareStack macOS 보안 구조 조사 보고서

작성일: 2026-10-28 (한국 시간)

기준 소스: `change-7/share-stack`의 `70524cb` (2026-10-19). 2026-10-28 작업 트리에 후속 보안·기능 변경이 추가됐으므로, 이 보고서는 해당 변경 이후 소스의 재감사가 아니다.

## 1. 조사 범위와 판정 기준

대상은 현재 작업 폴더의 **macOS 앱, Finder Share Extension, App Group, macOS MCP 서버·GUI 브리지·HTTP 전송 인터페이스**다. Android 앱 소스와 그 조사 결과는 제외했다. 휴대전화는 맥 HTTP API의 외부 호출자라는 범위에서만 다룬다. LinkDeck·ChatGPT의 내부 소스, 실제 방화벽·VPN·TCC·Keychain ACL은 조사하지 않았다.

이 보고서의 ‘코드로 검증됨’은 실제 함수와 호출 경로를 정적으로 추적했다는 뜻이다. 이번 분석 중 공격 재현, 앱 빌드·재설치, 권한·설정 변경, 기존 수신함 파일의 저장·삭제는 수행하지 않았다. 요청서와 완성 보고서의 ShareStack 읽기·등록만 별도 허용된 동작이다. 과거 기능 테스트의 성공이 아래 보안 통제를 입증한다고 간주하지 않는다.

현재 정책과 사용자가 요구한 목표 정책을 구분한다. 현재 구현은 연결 승인과 파일 수신을 신뢰하지만, 목표는 **AI 기본 거부·파일별 별도 승인·최소 목록 노출·AI 읽기 전용 기본 모드·임의 경로 금지·승인 만료와 철회**다. 이 차이를 확인된 설계 격차로 기록하며, 인증 없는 인터넷 공격이 가능하다고 확대 해석하지 않는다.

소스 기준 지문: macOS 하위 `.swift`, `.plist`, `.entitlements`, `.pbxproj`, `.json` 파일의 경로와 바이트를 정렬해 결합한 SHA-256은 `5f0bfa684f9ae8c9f4aa89f53dfb9746378aea756695450386433048594ac909`이다. 사용자 문서·토큰·키·실제 파일 내용은 포함하거나 기재하지 않았다.

## 2. 실제 데이터 흐름과 신뢰 경계

```text
ChatGPT / LinkDeck [외부 호스트 내부 승인·보존 정책은 미확인]
  → 앱 실행 파일 --mcp / stdio JSON-RPC
  → MCPServer: 도구명·인자 schema 검사
  → GUIBridge: 고정 루프백 HTTPS + 인증서 pin + Keychain Bearer
  → TransferHTTPServer: Bearer 인증 → 각 route
  → TransferJobs / TransferStore → 파일·메타데이터·작업 결과
  → 실제 텍스트 내용이 MCP 응답으로 호스트에 전달

Finder에서 사용자가 공유한 파일
  → sandbox Share Extension / NSItemProvider file URL
  → security-scoped 접근 중 원본 열기·안전 복사·해시
  → App Group / ShareStackIncoming / batch UUID / 파일·manifest
  → GUI의 비동기 가져오기 → 기존 임시 수신함
  → 저장 수락 시 별도 설정의 최종 저장 폴더로 이동

허용된 네트워크 주소의 클라이언트
  → 같은 TLS listener + 공통 Bearer
  → 업로드·발신 대기 파일 다운로드·일부 수신함 제어·공유 파일 조회
```

근거: `macos/ShareStackMac/Sources/ShareStackMac/ShareStackMacApp.swift:7-15,193-216`, `MCPServer.swift:53-113,126-178`, `GUIBridge.swift:65-126`, `TransferHTTPServer.swift:45-70,169-178`, `ShareStackShareExtension/ShareViewController.swift:27-142`, `Sources/ShareStackMac/TransferStore.swift:885-924`. 위처럼 짧게 적은 Swift 파일명은 모두 `macos/ShareStackMac/Sources/ShareStackMac/` 기준이다.

### 컴포넌트별 실제 권한

| 컴포넌트 | 코드상 권한·입력 | 실제 강제되는 통제 | 통제가 확인되지 않은 부분 |
|---|---|---|---|
| 맥 본체 | 사용자 권한으로 앱 데이터·설정한 저장 폴더·입력 경로 파일 처리 | Keychain, 일부 전용 디렉터리 권한, 파일 형식·크기·해시 검사 | 본체 entitlement에 App Sandbox 없음. 파일별 AI 허용 목록 없음. 실제 TCC/FDA 허용 상태는 미확인 |
| Finder 확장 | 공유된 file URL과 App Group 접근 | 확장 sandbox, security scope 종료, 일반 파일 검사, `O_NOFOLLOW`, 전용 복사본 | App Group은 AI 승인 경계가 아님. 실제 OS의 서명·그룹 접근 집행은 이번에 재검증하지 않음 |
| MCP 프로세스 | stdio 도구 호출과 GUI 연결 | JSON-RPC 상태·인자 검사, 도구별 입력 상한 | stdin 호출자 신원이나 사용자 클릭 증명 없음. annotation은 권한 검사 아님 |
| GUIBridge | 공통 Bearer를 Keychain에서 읽어 루프백 호출 | 인증서 pin, 고정 URL, proxy 비활성화, redirect 거부, 요청 제한 시간 | LinkDeck 전용 principal 또는 도구별 scope 없음 |
| HTTP listener | 포트 8765의 TLS 연결 | 허용 원격 주소, 공통 Bearer, 일부 route의 loopback 검사 | 장치별 identity·token revoke·scope·파일별 AI consent 없음 |
| TransferStore | ID→수신·발신·저장 위치 매핑 | UUID 생성, 표시 이름 정리, 수신 해시 검사, 잠금, 일부 원자적 메타데이터 쓰기 | 수신 상태와 AI 공개 상태 분리 없음. 저장된 내용의 identity 재검증 없음 |

entitlement 근거: `macos/ShareStackMac/ShareStackMac.entitlements:1-9`, `macos/ShareStackMac/ShareStackShareExtension/ShareStackShareExtension.entitlements:1-12`, `macos/ShareStackMac/ShareStackMac.xcodeproj/project.pbxproj:110-115`. Full Disk Access는 entitlement 유무만으로 실제 허용 상태를 판정할 수 없으며, 본체가 sandbox 밖이라고 모든 Mac 파일에 접근할 수 있는 것도 아니다. 실제 읽기 가능 범위는 사용자·파일시스템 권한과 OS 개인정보 보호에 제한된다.

## 3. 파일 종류·상태·출처별 접근 범위

| 영역 / 상태 | 현재 AI·MCP에서 가능한 접근 | 공통 토큰을 가진 허용 네트워크 피어 | 수명·제약 |
|---|---|---|---|
| Finder App Group 전달 대기열 | 직접 목록·읽기 API 없음. 가져오기 뒤 수신함에 노출 | 전달 대기열 자체의 HTTP 읽기 API 없음 | manifest 검증 뒤 가져옴. 성공한 batch는 제거 시도 |
| Finder·휴대전화·`add_inbox_files`·직접 텍스트 수신의 대기 파일 | `list_inbox`, `list_shared_files`, info, UTF-8 text read. 별도 AI 승인 전에도 가능 | inbox/shared-files 경로에 loopback 제한이 없어 같은 Bearer로 호출 가능 | 저장 수락은 AI 읽기 승인이 아님 |
| 위 파일을 저장 수락한 뒤 | `isShared=true`인 saved 항목은 shared-files 목록·info·텍스트 읽기 유지 | shared-files 경로를 통해 동일하게 접근 가능 | `savedPath`를 계속 따라감. TTL 없음 |
| 수신함의 PDF·이미지·일반 바이너리 | 메타데이터 가능, `read_shared_file` 텍스트 읽기는 거부 | pending 항목의 기존 `/v1/items/{id}/content`는 바이너리도 반환 가능 | 텍스트 도구의 형식 제한이 모든 HTTP 다운로드 경로의 제한은 아님 |
| Mac→휴대전화 발신 대기열 | `list_outbox`, `get_item`; shared-files 텍스트 목록 대상은 아님 | `/v1/pending` 목록과 item content로 내려받을 수 있음 | ack 후 메타데이터 제거와 복사본 삭제 시도 |
| 일반 저장 폴더의 공유 이력 없는 파일 | ID 기반 shared-files 도구가 폴더를 탐색하지는 않음. 다만 경로 도구로 가져올 수 있음 | 원격 피어에게 임의 경로 인자 job은 loopback 검사로 차단 | 맥의 경로 도구가 현재 접근 경계를 넓히는 핵심 |
| 삭제·취소된 수신 항목 | 이후 새 ID 조회는 찾지 못함 | 이후 새 item 조회도 거부 | 이미 응답한 내용과 호스트 측 사본은 회수 불가. 열린 FD로 진행 중인 read의 엄격한 철회는 별도 문제 |
| 저장 폴더에서 실제 파일만 삭제 | shared-files 목록 메타데이터는 남고 `unavailable`; 읽기 거부 | 같은 상태 | 파일명·시각·해시 등 이력 메타데이터가 자동 제거되지는 않음 |

근거: `TransferStore.swift:170-172,397-436,581-671,678-685,792-874,936-946,967-980`; `TransferHTTPServer.swift:180-195,303-336,341-403,457-524`.

중요한 출처 구분 한계: `insertReceivedLocked`는 Finder·MCP 가져오기·네트워크 수신을 모두 `origin: "galaxy"`, `state: "awaitingAcceptance"`, `isShared: true`로 생성한다(`TransferStore.swift:397-413`). 따라서 현재 `origin`이나 `isShared`를 ‘사용자가 ChatGPT 공개를 승인했다’는 증명으로 사용할 수 없다.

## 4. 확인된 문제 상위 5개와 성립 조건

아래 P0/P1은 **개선 설계의 우선순위**이며 CVSS의 Critical 등급을 뜻하지 않는다. 악용 재현은 수행하지 않았다.

### 4.1 P0 — 경로 도구가 UI 선택 없이 로컬 파일을 가져오거나 발신할 수 있음

**코드로 검증됨.** `MCPServer.swift:46-47`의 `send_files`, `add_inbox_files`는 `paths` 배열을 받는다. `MCPServer.swift:167-177`이 이를 job의 `filePaths`로 그대로 넘긴다. `TransferJobs.swift:27-30`은 절대 경로·개수·NUL만 검사하며, `183-192`에서 일반 파일·최종 심볼릭 링크 검사를 거쳐 store 함수로 전달한다.

```swift
// TransferJobs.swift:27-30
case .sendFiles, .importFiles:
    guard let filePaths, (1...16).contains(filePaths.count),
          filePaths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw JobError.invalidInput }
```

민감 동작은 `TransferStore.swift:694-720`의 `copyItem`이다. GUI `addFiles()`는 `NSOpenPanel`을 사용하지만(`ShareStackMacApp.swift:357-370`) MCP 요청에는 그 선택을 거쳤다는 증명이 없다. `startAccessingSecurityScopedResource()` 호출도 이미 주어진 URL에 대한 접근 시작 시도이며 사용자 선택·파일별 AI 승인을 새로 생성하는 절차가 아니다.

**공격 성립 조건:** 호출자가 해당 MCP 도구를 실행할 수 있어야 하고, 지정한 파일을 ShareStack 프로세스가 실제로 읽을 수 있어야 한다. `add_inbox_files`로 가져온 텍스트는 공유 파일 읽기로 돌아갈 수 있고, `send_files`는 휴대전화가 가져갈 발신 대기열에 사본을 만든다. 발신 job 성공만으로 실제 휴대전화 전송 완료를 뜻하지는 않는다.

**기존 방어책:** loopback-only job route, Bearer, regular-file 검사, 최종 symlink 거부, 작업당 16개, 원본 보존. 이것들은 사용자 선택 증명이나 허용 경로 제한을 대체하지 않는다. LinkDeck의 실제 per-call 확인은 미확인이므로 ‘ChatGPT가 현재 사용자의 확인 없이 항상 호출할 수 있다’고 단정하지 않는다.

**권고:** AI 경로에서는 임의 `paths`를 거부하고 UI가 발급한 일회성 handle 또는 승인 파일 ID만 허용한다. 기존 본체 파일 선택·Galaxy 발신 흐름은 유지한다. 정책 격차의 영향은 크지만 인증된 MCP 호출 권한과 OS 읽기 가능성이 필요하므로 무인증 원격 파일 읽기로 분류하지 않는다.

### 4.2 P0 — 수신·저장 상태가 곧 AI 목록·읽기 범위가 됨

**코드로 검증됨.** `TransferStore.swift:670-671`은 아래 상태 분류만 사용한다.

```swift
private static func isSharedFile(_ item: TransferItem) -> Bool {
    item.origin == "galaxy" && (item.isShared == true || isAwaitingAcceptance(item))
}
```

`sharedFiles`(`812-823`), `sharedFileInfo`(`826-838`), `readSharedFile`(`841-874`)는 이 분류를 사용하며, `aiReadAllowed`, 승인 주체, 만료, 철회 세대 같은 검사는 없다. 저장 수락 후에도 `isShared=true`를 유지한다(`604-609`). UI에는 저장·취소와 수신 설정이 있지만 별도 AI 허용 토글은 없다(`ReceiptViews.swift:38-100,170-184`).

**공격 성립 조건:** 유효한 MCP 연결 또는 해당 HTTP 경로를 호출할 공통 Bearer가 필요하다. 사용자가 Finder/휴대전화로 넣은 파일이 있어야 한다. 그 조건에서 파일명·메타데이터를 열거하고 지원 텍스트 내용을 읽을 수 있다. UUID는 식별자이며 목록이 UUID를 알려주므로 별도 권한 증명이 아니다.

**기존 방어책:** 텍스트 종류 제한, 32 KiB 청크, UTF-8 검사, UUID와 실제 파일 상태 검사, 인증. 그러나 전부 사용자가 요구한 파일별 AI 승인을 대신하지 않는다. `list_shared_files`만 숨겨도 `list_inbox`, `get_item`, `list_events`, `get_status` 등의 메타데이터 우회 노출을 함께 검토해야 한다.

**권고:** intake state와 AI grant를 분리하고 모든 AI 목록·info·read 경로에서 동일한 기본 거부 정책을 적용한다. 미승인 파일명과 승인 여부를 구분할 수 있는 정보도 기본적으로 반환하지 않는다.

### 4.3 P0 — 맥 내부·휴대전화 API가 같은 장기 토큰을 공유하고 route별 범위가 불균일함

**코드로 검증됨.** `NetworkIdentity.swift:84-123`은 Keychain에서 기존 32-byte random token을 재사용하고 없을 때만 만든다. `GUIBridge.swift:84-101`도 같은 토큰을 사용한다. `TransferHTTPServer.swift:169-178`의 공통 Bearer 검사를 거친 뒤 `routeSharedFiles`, `routeJobs`, `routeControl` 순서로 분기한다.

`/v1/jobs`에는 명시적인 loopback 원격주소 검사가 있다(`396-403`). 반면 `/v1/shared-files*`(`341-395`)와 `/v1/inbox`, `/v1/status`, `/v1/events`, 저장 수락·삭제 경로(`457-524`)에는 그 검사가 없다. 따라서 **공유 파일 읽기가 localhost 전용이라는 가정은 현재 코드와 다르다.**

**공격 성립 조건:** RFC1918 또는 Tailscale IPv4 등 허용 주소에서 서버에 도달할 수 있고 공통 토큰을 보유해야 한다. 같은 Wi-Fi라는 이유만으로 토큰 없는 기기가 업로드·다운로드할 수 있는 것은 아니다. 반대로 이미 토큰을 가진 기기는 서버가 장치별·작업별 권한을 구별하지 않으므로 일반 휴대전화 전송을 넘어 수신함·saved 텍스트에 도달할 수 있다.

**기존 방어책:** TLS, 암호학적 난수, Keychain, 길이 비교 뒤 XOR 누적 방식의 Bearer 비교(`795-799`), 허용 주소 필터(`802-805`), job의 loopback 제한. 실제 토큰 탈취나 외부 프록시 구성은 확인하지 않았다. 저장소에서 장치별 revoke/rotate/expiry API는 발견하지 못했다.

**권고:** 모바일 장치 credential과 AI 세션 credential을 분리한다. 별도 loopback listener를 쓰거나 모든 route에 principal·audience·operation scope를 검사한다. AI 전용 route 차단만으로 기존 LAN의 `/v1/items/{id}/content`·`/v1/inbox` 우회가 남지 않도록 한다. 장치별 폐기와 재페어링 경로가 필요하다.

### 4.4 P1 — 저장된 SHA-256은 읽는 바이트의 신원을 보장하지 않음

**검증된 사실 / 조건부 위험.** 수신과 이동 시 SHA-256을 검사하지만 `sharedFileInfo`는 저장된 해시를 반환한다(`826-838`). `sharedFileURL`은 regular-file·symlink·크기만 확인하고(`936-939`), `readSharedFile`의 `open(O_NOFOLLOW)`·`fstat`도 파일 종류와 크기만 비교한다(`856-862`). 저장된 해시, inode, device ID, 수정 세대는 읽기 시 비교하지 않는다.

**성립 조건:** saved 경로나 임시 파일·부모 경로를 수정할 권한이 있는 다른 주체, 공유 폴더, 또는 사용자의 후속 편집이 필요하다. 동일 길이의 교체·편집은 과거 ID와 해시 아래에서 다른 내용으로 읽힐 수 있다. 최종 경로의 symlink 방지는 유효하지만 부모 디렉터리 교체와 hardlink, 열린 파일의 수정까지 모두 차단한다는 뜻은 아니다. 현재 미승인 읽기 문제와 별개로, 향후 ‘특정 내용에 승인’하는 설계의 필수 보완점이다.

**반증·한계:** 로컬 쓰기 권한이 이미 필요한 경우가 많아 독립적인 무인증 원격 권한 상승으로 보고하지 않는다. 기본 전용 디렉터리 0700도 공격 표면을 줄인다. 실제 레이스·hardlink 공격은 실행하지 않았다.

**권고:** 승인 대상을 파일 ID뿐 아니라 내용 버전·크기·해시와 결합한다. 신뢰한 directory FD 아래에서 파일을 열고 opened object를 검증한다. 저장 경로에서 파일이 바뀌면 기존 승인을 폐기하고 재승인을 요구한다. 큰 파일을 청크마다 통째로 해시하는 비효율을 피할 설계는 개선안에 구분했다.

### 4.5 P1 — 개별 상한은 있으나 누적 용량·대기 작업·복사 중 상한은 부족함

**코드로 검증된 상한:** 직접 텍스트 128 KiB(`TransferJobs.swift:24-26`), MCP text read 32 KiB(`TransferStore.swift:854`), 경로 작업·Finder 최대 16개, 파일당 20 GiB, 업로드 청크 8 MiB, HTTP 연결 32개, 비처리 idle 120초(`TransferHTTPServer.swift:4-13,81-88`). 완료 job은 600초·20개로 제한한다(`TransferJobs.swift:135-145`).

**빠진 경계:** `beginUpload`는 aggregate bytes/session count를 검사하지 않는다(`TransferStore.swift:281-338`). 오래된 upload 정리는 `init`에서 호출되는 24시간 기준 정리다(`192-204`). 전체 inbox·saved 이력·App Group 대기열·queued job에 대한 총량·속도 제한을 확인하지 못했다. queued/running job은 terminal job 보존 상한과 별개다.

로컬 경로 import/send는 `copyItem`을 수행한 뒤 해시·20 GiB 검사를 한다(`694-720,751-755`). 따라서 ‘20 GiB 제한이 있으므로 초과 크기의 복사가 시작되지 않는다’는 주장은 성립하지 않는다. Finder 확장은 시작 시 size를 검사하지만 복사 loop 안에서 증가 중인 source의 누적 바이트를 즉시 중단하지 않는다(`ShareViewController.swift:109-133`). 최종 크기 불일치는 나중에 오류가 된다.

**공격 성립 조건:** 대량 업로드에는 공통 토큰과 네트워크 도달성이, 로컬 경로 복사에는 MCP 호출 권한과 읽을 수 있는 경로가 필요하다. 크기·디스크 고갈 테스트는 하지 않았다. 연결 슬롯은 인증 전에도 사용되므로 미인증 허용 네트워크 피어의 자원 점유도 별도 검토 대상이며, 이를 곧바로 데이터 유출로 취급하지 않는다.

**권고:** 수신함·업로드·대기열 총량, free-space reserve, 호출별/장치별 예산, 작업 queue 깊이, chunk별 bounded copy, 동작 중 청소 정책을 추가한다. 정상 대용량 Galaxy 전송을 유지하는 값과 거부 응답을 명시해야 한다.

## 5. 요청된 7개 분야의 세부 확인

### 5.1 접근 경계·인증·호출자 구분

- **코드로 검증됨:** 본체가 `NWListener(using:on:)`를 만들며 특정 인터페이스에 bind하지 않는다(`TransferHTTPServer.swift:45-51`). 이후 remote endpoint가 loopback·RFC1918·Tailscale IPv4인지 검사한다(`116-138,802-805`). UI의 Wi-Fi/Tailscale 선택은 페어링 주소 필터만 바꾸며 listener를 재설정하지 않는다(`ShareStackMacApp.swift:148-164`).
- **미확인:** 실제 OS 방화벽, Wi-Fi client isolation, tailnet ACL, NAT/포트포워딩·reverse proxy. 공개 인터넷에서 직접 사용 가능한 서비스라고 단정할 근거는 없다. 반대로 사설 IP 검사만으로 특정 페어링 장치임을 증명하지도 못한다.
- **코드로 검증됨:** GUIBridge는 고정 루프백 URL, ephemeral URLSession, 빈 proxy 설정, redirect 거부, 파일의 GUI fingerprint와 인증서 hash 비교를 사용한다(`GUIBridge.swift:13-36,51-63,84-126`). 이것은 서버 인증이며 호출자별 사용자 승인 검사는 아니다.
- **토큰 보호:** 난수와 Keychain을 사용하고 실제 토큰을 MCP status에 직접 내보내지 않는다. 페어링 QR URL에는 토큰과 pin이 포함되므로 QR 자체는 비밀로 다뤄야 한다(`ShareStackMacApp.swift:154-164`). 값·QR은 조사하거나 첨부하지 않았다.
- **TLS 개인키 보호:** 암호화 PKCS#12와 별도 Keychain password, root/work 0700 및 archive/key 0600, macOS 15 이상 memory-only import가 있다. OpenSSL은 고정 실행 경로와 배열 인자를 쓰며 비밀번호는 자식 환경변수로 전달한다(`TLSIdentity.swift:23-105`). 원시 개인키를 읽지 않았다. 구형 archive 이행 코드가 존재하지만 실제 legacy 파일의 잔존 여부는 미확인이다.
- **재전송·만료:** 토큰은 장기 Bearer이며 요청별 nonce·서명·scope·장치 identity를 확인하지 않는다. TLS가 전송 기밀성과 네트워크 재생 방어의 기본 통제다. 별도 nonce 부재만으로 TLS 우회를 주장하지 않는다. 토큰이 유출되면 유효한 반복 호출을 앱 수준에서 독립 폐기하기 어려운 점이 문제다.
- **CSRF/CORS/DNS rebinding:** server parser에 Origin·Host 허용 목록은 없고 CORS 허용 응답도 확인하지 못했다. Authorization header와 TLS가 있어 일반 웹페이지가 자동 인증되는 cookie CSRF와 동일하지 않다. GUIBridge는 DNS 이름을 쓰지 않아 그 경로의 DNS rebinding 영향은 줄어든다. 브라우저 기반 공격의 실제 성립은 재현하지 않았다. HTTP parser는 중복 header와 Transfer-Encoding을 거부하고 연결을 닫는다(`TransferHTTPServer.swift:831-861`).

### 5.2 파일 공개·목록·승인 수명

- `read_shared_file`은 임의 path를 직접 받지 않고 저장된 ID로 한정된다. 그러나 모든 수신 파일을 승인된 것으로 분류하는 현재 predicate와 path import 도구 때문에 ‘명시적으로 AI에 허용한 파일만’이라는 목표는 충족하지 않는다.
- 미승인 파일명·해시·수신 시각도 shared/inbox 목록으로 노출된다. `get_status`에는 실제 저장·임시 폴더 경로와 주소가 포함된다(`TransferHTTPServer.swift:445-479`). 실제 사용자 값은 이 문서에 복사하지 않았다.
- 수락과 saved 메타데이터는 재시작 후에도 유지된다. AI grant 만료·일시정지·철회 필드는 없고, 수신함 파일 TTL도 없다. 미완료 upload의 24시간 정리는 AI 승인 만료가 아니다.
- 삭제는 store 항목과 임시 파일을 제거하며 실패 시 복구를 시도한다(`TransferStore.swift:621-664`). 저장본이 외부에서 사라지면 읽기는 막지만 이력 메타데이터는 남긴다. 이미 전달된 응답, ChatGPT/LinkDeck의 캐시·대화 보존은 앱이 회수할 수 있는 범위가 아니며 외부 정책은 미확인이다.
- read는 항목 검사 후 lock을 풀고 파일을 연다(`841-867`). 삭제·철회와 경쟁하는 이미 열린 read를 최종 응답 직전에 다시 승인 검사하는 로직은 없다. 향후 ‘즉시 철회’는 이 경쟁 조건의 의미까지 정해야 한다.

### 5.3 경로·일괄 처리·파괴적 도구

- 경로 도구의 주된 문제와 반증은 4.1에 기재했다. 절대 경로·regular-file·no-symlink는 형태 검사이며 UI 선택 증명이나 허용 범위가 아니다. 부모 symlink 또는 source의 검사 후 교체까지 descriptor 기반으로 결합하지 않는다.
- `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`와 ‘사용자 요청 시에만’ 문구는 반환 metadata다(`MCPServer.swift:13-22,41-50`). `tools/call`은 schema 검사 후 dispatch한다(`95-112`). 서버가 사용자 승인 기록을 확인하는 통제는 없다.
- `receive_all`은 실행 시 inbox ID를 수집하고, cancel/send/import job도 이어서 실행한다(`TransferJobs.swift:155-193`). 요청 당시 파일 집합·해시와 사용자가 확인한 대상 집합을 묶는 확인 토큰은 없다. host가 실제로 별도 확인하는지 미확인이므로 서버 통제 부재와 host 보장 미확인을 나눠 판단해야 한다.
- `cancel_job`은 남은 항목의 취소 요청이며 이미 완료된 복사·저장을 되돌리지 않는다. 진행 중 한 파일도 먼저 끝날 수 있다(`TransferJobs.swift:109-118,169-193`). 요청 취소가 원자적 전체 rollback이라는 보장은 없다.

### 5.4 Finder 확장·App Group·원본 접근

- 확장은 file URL을 `loadItem`으로 받고 URL/Data 표현을 해석한다. 복사 중 security scope를 시작하고 `defer`로 종료한다. 영구 bookmark를 저장하는 코드나 앱에 원본 URL을 넘겨 계속 여는 코드는 확인하지 못했다.
- 원본은 `O_RDONLY | O_NOFOLLOW`, `fstat` regular-file, 복사본은 UUID 이름과 `O_EXCL`·0600이다. 이름은 manifest의 표시 이름이며 app import에서 안전 이름으로 정리한다. 최종 manifest는 전체 복사 성공 후 atomic write한다(`ShareViewController.swift:27-142`).
- App Group 루트·batch 파일 디렉터리 0700, data/manifest 0600을 사용한다. 일반적인 다른 UID 접근을 줄이는 통제지만, 같은 사용자·동일 그룹 권한 앱·ACL·선택 볼륨의 실제 권한 집행은 소스만으로 보장하지 않는다. 공유 그룹 접근은 사용자별 AI 승인과 다른 경계다.
- GUI importer는 batch/entry UUID, batch ID 일치, 중복 ID, 파일 수·크기·SHA 형식과 실제 해시를 확인한다. 전체 batch 성공 후만 삭제를 시도한다(`TransferStore.swift:885-924`). manifest를 먼저 메모리에서 decode하므로 다른 group writer가 있는 위협 모델에서는 manifest 자체의 바이트 상한도 필요하다. 그러한 writer의 실제 존재·권한은 미확인이다.
- 실행 가능한 일반 파일도 바이트로 복사될 수 있다. 앱 bundle·폴더는 regular-file 검사에 맞지 않는다. 압축 해제, macro 실행, 수신 파일 자동 실행·자동 열기 sink는 조사한 수신 경로에서 발견하지 못했다. 내용이 안전하거나 악성코드 검사를 통과했다는 뜻은 아니다.

### 5.5 파일 검증·원자성·임시 정리·자원

- 이름은 마지막 경로 성분을 취하고 제어 문자 제거·공백 정리·길이 제한을 적용한다(`TransferStore.swift:1027-1031`). 저장 수락 시 같은 이름은 번호를 붙인다(`581-603`). 확장자/MIME는 텍스트 판정에 OR로 쓰이며 실제 내용은 UTF-8 decode로 확인한다(`942-954`). MIME·확장자만으로 파일의 진위를 검증하지 않는다.
- SHA-256은 전송·복사 무결성이지 사용자 인증, 파일별 권한, 서명, 악성코드 검사가 아니다. 공격자가 내용과 manifest를 모두 통제한다면 hash가 일치하는 악성 데이터도 만들 수 있다.
- 수신·복사본은 주로 UUID로 분리하며 일부 metadata는 `.atomic`으로 기록한다. 크로스볼륨 이동·설정 파일·payload를 하나의 filesystem transaction으로 묶은 것은 아니다. 전원 차단 crash consistency를 이번에 재현하지 않았다.
- 임시 보관 위치 변경은 새 전용 디렉터리 생성, 대기 파일 복사·해시 검사·synchronize, 설정 전환 후 원본 삭제 순서다. 실패 시 기존 경로를 유지한다. 이전 위치 cleanup 실패는 복사본 잔존 수로 알린다(`TransferStore.swift:448-521`). 개인정보 보존 설계에서는 잔존본 재처리 정책이 필요하다.
- 원본·부모 디렉터리의 symlink, hardlink, 파일 변경은 모든 경로에서 동일하게 descriptor 검증하지 않는다. extension의 source FD 검사, MCP path job의 사전 resourceValues 검사, read의 O_NOFOLLOW를 각각 구별해야 한다.
- 4.5의 자원 상한 격차 외에도 큰 JSON 목록은 HTTP 응답에 전체 인코딩한 뒤 MCP에서 pagination하는 경로가 있다(`MCPServer.swift:132-158`, `TransferHTTPServer.swift:478-479,755-765`). GUIBridge의 8 MiB 확인도 수신 data가 생성된 뒤의 확인이다(`107-111`).
- 파일 안의 지시문을 직접 실행하는 코드는 없다. 하지만 이 텍스트를 읽은 모델이 다시 경로·삭제 도구를 호출할 수 있는 구조에서 prompt injection의 위험은 별도다. 프롬프트 설명만으로 방어하지 말고, 서버가 데이터와 실행 권한을 분리해야 한다.

### 5.6 맥의 네트워크·휴대전화 전송 경계

- Mac 측 페어링은 host·Bearer·certificate fingerprint를 QR URL로 제시한다. 맥 서버가 휴대전화 device ID·장치별 token record를 확인하는 방식은 아니다. 이 보고서는 Android 소스를 분석하지 않았으므로 휴대전화 클라이언트 구현의 pinning·저장·intent 처리를 판정하지 않는다.
- Mac은 TLS identity를 설정한다. HTTP의 공통 token 인증과 endpoint 주소 검사만으로도 토큰 없는 일반 같은 Wi-Fi 기기의 API 사용은 차단한다. TLS handshake 이전 자원 점유까지 없애는 것은 아니다.
- Tailscale 주소 범위를 허용하지만 Tailscale 사용자·device identity·tailnet ACL 자체를 API가 검사하는 것은 아니다. 외부 proxy가 loopback source를 만들면 `/v1/jobs`의 local-only 분류가 실제 외부 caller와 달라질 수 있으나, 실제 proxy 구성은 확인되지 않았다.
- 기존 `/v1/items/{id}/content`는 pending item의 파일을 별도 text 제한 없이 반환한다. saved 항목은 `item(for:)`에서 제외되므로 이 기존 경로로 saved 전체가 곧바로 공개된다고 하지는 않는다. saved 텍스트는 별도의 shared-files 경로가 공개한다. 이 구분을 유지해 route 우회 테스트를 설계해야 한다.

### 5.7 감사·승인 UI·복구

- 현재 이벤트는 수신·저장·실패·취소 중심의 메모리 200개 ring이고 stream ID는 재시작 시 바뀐다(`TransferStore.swift:142-144,560-578`). 호출 principal·허용/거부 결정·read 범위·승인 변경을 내구성 있게 기록하는 구조는 아니다.
- UI는 수신 방식, 저장 폴더, 임시 보관 폴더, 저장 수락·취소를 제공한다. AI 파일별 허용, 만료, 승인 철회, 전체 AI 읽기 일시정지, 최근 AI 접근 목록은 확인하지 못했다.
- 실패 job에는 target과 error를 보관하고 일부 오류를 stderr로 쓴다(`TransferJobs.swift:197-224`). 이 값에 경로 등이 들어갈 수 있으므로 향후 감사 로그에는 안전한 target ID와 error code만 사용해야 한다. 실제 로그를 열람하거나 report에 인용하지 않았다.
- 기본 AI 읽기를 거부해도 본체 수신함·Galaxy 업로드/발신 기능 자체를 멈출 필요는 없다. 현재 공유하는 저장 helper 위에 AI principal·grant gate를 별도로 두고, 본체 UI 및 장치 transfer 권한과 분리하는 것이 최소 변경 경로다.

## 6. 검증 상태와 남은 조사

| 판정 | 내용 |
|---|---|
| 코드로 검증됨 | path 도구의 실제 복사 경로, 별도 AI grant 부재, 모든 수신 출처의 공유 분류, saved read 지속, 공통 Bearer, jobs만 loopback 검사, 기존 파일 삭제와 이동 로직, initial hash와 read identity 검사의 차이, 개별 제한과 누적 제한 부재 |
| 취약 가능성·조건부 | 승인된 MCP 연결의 오용, 토큰 유출 뒤 광범위한 route 접근, 수정 가능한 저장본의 같은 크기 교체, 부모 경로·hardlink·진행 중 read 경쟁, 인증된 대량 적재·미인증 연결 점유 |
| 미확인 | LinkDeck 실제 per-call 승인·로그·클라우드 보존, 실제 OS/TCC/FDA/Keychain ACL/파일시스템 권한, 방화벽·VPN ACL·proxy, 전원 차단·레이스·큰 파일·디스크 고갈 재현, macOS 실제 설치 바이너리와 소스의 완전한 동일성 |

소스코드 수정, 앱 설정·권한 변경, 실제 공격, 기존 수신 파일 삭제는 이 보고서의 결과가 아니다. 개선 정책의 적용과 검증은 별도 구현 작업이다.
