// node_modules에 설치된 라이브러리를 www/lib로 복사해서 앱이 인터넷 없이도 동작하게 합니다.
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..');
const out = path.join(root, 'www', 'lib');
fs.mkdirSync(out, { recursive: true });
const files = [
  ['pdf-lib/dist/pdf-lib.min.js', 'pdf-lib.min.js'],
  ['pdfjs-dist/build/pdf.min.js', 'pdf.min.js'],
  ['pdfjs-dist/build/pdf.worker.min.js', 'pdf.worker.min.js'],
  ['jszip/dist/jszip.min.js', 'jszip.min.js'],
  ['qrcode-generator/qrcode.js', 'qrcode.js'],
  ['jsqr/dist/jsQR.js', 'jsQR.js'],
];
let ok = true;
for (const [src, dst] of files) {
  const from = path.join(root, 'node_modules', src);
  if (!fs.existsSync(from)) { console.error('찾을 수 없음:', src, '→ 먼저 npm install 을 실행하세요'); ok = false; continue; }
  fs.copyFileSync(from, path.join(out, dst));
  console.log('복사함:', dst);
}
if (!ok) process.exit(1);
