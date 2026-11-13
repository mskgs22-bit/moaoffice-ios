# MoaOffice for iOS

오프라인 통합 문서 뷰어 (PDF · HWP · HWPX · DOC · DOCX · XLS · XLSX · CSV · AI · PSD).
Mac 없이 **Codemagic** 클라우드 Mac 에서 빌드·테스트·TestFlight 업로드한다.

| 형식 | 엔진 |
|---|---|
| PDF, AI | PDFKit (형광펜·밑줄·취소선 주석, 저장) |
| HWP 5.x | 자체 파서 (CFB + raw deflate) — 문단·표 |
| HWPX | 자체 파서 (ZIP + OWPML XML) — 문단·표 |
| DOC/DOCX/XLS/XLSX/CSV | Quick Look (iOS 내장) |
| PSD/PSB | ImageIO, 실패 시 Quick Look |

- HWP/HWPX → PDF 내보내기 (기기 안에서 처리)
- 광고: Google Mobile Ads 12 (배너 + 문서 3회마다 전면) — 구독 시 제거
- 구독: StoreKit 2 `com.moaoffice.app.adfree.monthly` / `.yearly` (그룹 *MoaOffice Premium*)
- 언어: 영어(기본) / 한국어

## 빌드
- `ios-test` : main 에 push 하면 자동. 시뮬레이터에서 예제 문서 6개를 열어 스크린샷(한/영)을 Artifacts 로 남긴다.
- `ios-release` : Codemagic 에서 수동 실행 → TestFlight.
  - Codemagic Team/Personal settings → Integrations → App Store Connect 에 API 키 등록 (이름 `MoaOffice ASC`)
  - Code signing identities 에서 iOS Distribution 인증서 생성, App Store 프로파일 가져오기
  - 환경변수 그룹 `admob` 에 실제 AdMob iOS ID 3개
