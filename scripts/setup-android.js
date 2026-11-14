// npx cap add android 다음에 실행: 인쇄 플러그인, 카메라 권한, 광고 앱 ID, 결제 권한 추가
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..');
// ▼ AdMob 앱 ID (포켓 스캐너)
const ADMOB_APP_ID = 'ca-app-pub-9038740106483632~3117432478';

const pkgDir = path.join(root, 'android/app/src/main/java/kr/pocketscanner/app');
if (!fs.existsSync(path.join(root, 'android'))) { console.error('android 폴더가 없어요. 먼저 npx cap add android 를 실행하세요.'); process.exit(1); }
fs.mkdirSync(pkgDir, { recursive: true });
for (const f of ['MainActivity.java', 'WebPrintPlugin.java']) {
  fs.copyFileSync(path.join(root, 'android-extra', f), path.join(pkgDir, f));
  console.log('복사함:', f);
}
const mf = path.join(root, 'android/app/src/main/AndroidManifest.xml');
let xml = fs.readFileSync(mf, 'utf8');
const perms = [
  '<uses-permission android:name="android.permission.CAMERA" />',
  '<uses-feature android:name="android.hardware.camera" android:required="false" />',
  '<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29" />',
  '<uses-permission android:name="com.android.vending.BILLING" />',
  '<uses-permission android:name="com.google.android.gms.permission.AD_ID" />',
];
for (const p of perms) if (!xml.includes(p)) xml = xml.replace('</manifest>', '    ' + p + '\n</manifest>');
const metaRe = /<meta-data\s+android:name="com\.google\.android\.gms\.ads\.APPLICATION_ID"[^>]*\/>/;
const meta = `<meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="${ADMOB_APP_ID}" />`;
if (metaRe.test(xml)) xml = xml.replace(metaRe, meta);
else xml = xml.replace(/<application([^>]*)>/, (m) => m + '\n        ' + meta);
fs.writeFileSync(mf, xml);
console.log('AndroidManifest.xml 설정 완료 (카메라·결제 권한, AdMob 앱 ID)');
