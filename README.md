# 포켓 스캐너 — 안드로이드 앱 만들기

서버 없이 휴대폰 안에서만 동작하는 문서 스캐너 앱입니다.
앱으로 만들면 **실시간 카메라 화면**, **바로 인쇄**, **파일 저장**이 모두 됩니다.

---

## 1. 준비물 (PC에 한 번만 설치)

| 프로그램 | 받는 곳 | 비고 |
|---|---|---|
| Node.js (20 이상) | https://nodejs.org | LTS 버전 설치 |
| Android Studio | https://developer.android.com/studio | 처음 실행할 때 SDK가 자동으로 설치됨 |

Windows, Mac 둘 다 됩니다.

## ⚡ 가장 쉬운 방법 (Windows)

1. 이 폴더에서 **`build-android.bat` 더블클릭** → 테스트용 APK가 만들어지고 폴더가 열려요
2. Play 스토어에 올릴 때는 **`build-release.bat` 더블클릭** → 업로드용 `app-release.aab` 생성
   - 처음 실행할 때 정한 비밀번호와 `upload-key.jks` 파일은 **꼭 백업**하세요 (잃어버리면 앱 업데이트를 못 올려요)

## 2. 앱 만들기 (직접 명령어로 할 때)

이 폴더(`pocket-scanner-app`)에서 터미널(Windows는 명령 프롬프트)을 열고 차례로 실행하세요.

```bash
npm install
npm run setup
npm run open
```

- `npm install` : 필요한 부품 다운로드 (몇 분 걸려요)
- `npm run setup` : 안드로이드 프로젝트 생성 + 인쇄 기능·카메라 권한 추가 + 로고로 앱 아이콘 만들기
- `npm run open` : Android Studio가 열려요

## 3. 휴대폰에 설치하기

**방법 A — 케이블로 바로 설치**
1. 휴대폰 설정 › 휴대전화 정보 › 소프트웨어 정보 › **빌드번호 7번 탭** → 개발자 모드 켜짐
2. 설정 › 개발자 옵션 › **USB 디버깅** 켜기
3. USB로 PC에 연결 → Android Studio 위쪽에서 휴대폰 선택 → ▶ (Run) 버튼

**방법 B — APK 파일 만들기**
1. Android Studio 메뉴 **Build › Build App Bundle(s) / APK(s) › Build APK(s)**
2. 완료 알림의 `locate` 클릭 → `app-debug.apk`
3. 이 파일을 휴대폰으로 보내서 설치 (출처를 알 수 없는 앱 허용 필요)

## 4. 플레이스토어에 올리려면

1. Google Play Console 개발자 등록 (1회 25달러)
2. Android Studio **Build › Generate Signed App Bundle** → `.aab` 파일 생성
3. Play Console에 업로드 → 스토어 정보·스크린샷·개인정보처리방침 작성 → 심사

> 개인정보처리방침에는 "모든 사진과 문서는 기기 안에서만 처리되며 외부 서버로 전송하지 않습니다" 라고 쓰면 됩니다.

## 5. 앱을 고친 뒤에

`www/index.html`을 수정했다면:

```bash
npm run sync
```

그다음 Android Studio에서 다시 ▶ 실행.

---

## 💰 수익 설정 (출시 전에 꼭)

지금은 **구글 테스트 광고**가 나오도록 되어 있어요. 테스트 광고로는 수익이 안 나요. 출시 전에 아래를 진행하세요.

### 1) 광고 — AdMob
1. https://admob.google.com 가입 → **앱 추가** (Android, 패키지 이름 `kr.pocketscanner.app`)
2. **앱 ID** (`ca-app-pub-xxxx~yyyy`) → `scripts/setup-android.js`의 `ADMOB_APP_ID`에 넣기
3. **광고 단위 3개** 만들기: 배너 / 전면 / 보상형 → 각 ID를 `www/index.html` 맨 위쪽 `CONFIG`의 `adBanner`, `adInter`, `adReward`에 넣기
4. 같은 `CONFIG`에서 `adTesting:true` → **`false`**
5. `node scripts/setup-android.js` 다시 실행 → `npm run sync`

> ⚠️ 개발 중에는 **절대 내 광고를 직접 누르지 마세요.** 무효 클릭으로 AdMob 계정이 정지될 수 있어요. 테스트는 테스트 광고(`adTesting:true`)로 하세요.

**광고가 나오는 곳 (무료 사용자)**
- 배너: 홈·파일·도구·내 정보·문서 화면 아래쪽 (카메라·편집 화면엔 안 나옴)
- 전면: 스캔 완료, 저장·내보내기, 인쇄, QR 결과, 문서 열 때 — 최소 30초 간격
- 보상형: 프로 기능(지우개, ID 포토 인화 배치, PDF 압축)을 "광고 보고 1회 사용"

전면 광고 간격은 `CONFIG.interGapSec`으로 조절해요. 너무 줄이면(예: 10초) 구글 정책 위반으로 광고가 제한되거나 계정이 정지될 수 있어요. **30초 이상을 권장**해요.

### 2) 구독 — Google Play
1. Play Console에서 앱을 만들고, 먼저 **내부 테스트**로 한 번 업로드 (업로드해야 상품을 만들 수 있어요)
2. **수익 창출 › 정기 결제**에서 상품 2개 만들기
   - 상품 ID `pro_monthly` → 기본 요금제: 1개월 자동 갱신, **1,900원**
   - 상품 ID `pro_yearly` → 기본 요금제: 1년 자동 갱신, **11,900원**
3. **설정 › 라이선스 테스트**에 내 구글 계정 추가 → 실제 돈 안 나가고 결제 테스트 가능
4. 결제 프로필(사업자/계좌) 등록 필요

### 3) 관리자 코드 (이용권)
- 별도로 드린 **`admin-codegen.html`** 을 PC·휴대폰 브라우저로 열어서 코드를 만들어요 (인터넷 불필요)
- 기간: 1주일 / 1개월 / 6개월 / 1년 / 영구
- 사용자가 입력하는 곳: **내 정보 › 맨 아래 "포켓 스캐너 v1.0.0" 글자를 7번 연속 탭** → 숨겨진 코드 입력 화면
- 코드는 아무 기기에서나 쓸 수 있고, **발급 후 30일 안에** 등록해야 해요
- ⚠️ `admin-codegen.html`과 앱 안의 비밀키는 한 쌍이에요. 생성기 파일은 절대 공유하지 마세요.

### 4) Play 스토어 정보 입력 시
- **데이터 보안** 항목: "광고 ID 수집 (AdMob)" 체크, 사진·파일은 "수집 안 함(기기 내 처리)"
- **광고 포함** 체크
- 앱 안의 개인정보처리방침 문구를 그대로 웹페이지로 올려서 링크로 쓰면 돼요

---

## 앱에서 달라지는 점

| 기능 | Claude 안 (웹) | 앱 |
|---|---|---|
| 카메라 | 사진 찍은 뒤 처리 | **실시간 카메라 화면 + 모드 넘기기** |
| QR 스캔 | 사진으로 | **카메라만 비추면 자동 인식** |
| 저장 | 다운로드 | **내 파일 › 문서 › PocketScanner** 폴더에 저장 + 공유 |
| 인쇄 | PDF 저장 후 직접 인쇄 | **바로 안드로이드 인쇄 화면** |
| 뒤로가기 버튼 | - | 휴대폰 뒤로가기 버튼으로 이전 화면 |
| 인터넷 | 필요 | **필요 없음** (완전 오프라인) |

## 폴더 구성

```
pocket-scanner-app/
├─ www/index.html          앱 화면 전체 (맨 위 CONFIG에 광고·상품 ID)
├─ assets/                 앱 아이콘·시작 화면 원본 (로고)
├─ android-extra/          인쇄 기능 (자동으로 복사됨)
├─ scripts/                설정 자동화 스크립트
├─ package.json
└─ capacitor.config.json   앱 이름·패키지 이름
```

앱 이름을 바꾸려면 `capacitor.config.json`의 `appName`을 고치세요.

## 문제가 생기면

- `npm install` 오류 → Node.js 버전 확인 (`node -v` 가 20 이상인지)
- `npm run setup` 중 아이콘 단계 오류 → 무시하고 `npx cap sync android` 실행 (기본 아이콘으로 빌드됨)
- Gradle 오류 → Android Studio에서 **File › Sync Project with Gradle Files**
- 카메라가 안 켜짐 → 휴대폰 설정 › 애플리케이션 › 포켓 스캐너 › 권한 › 카메라 허용
