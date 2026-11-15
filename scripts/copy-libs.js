// node_modules의 라이브러리를 www/lib로 복사 (인터넷 없이도 스캔·생성 동작)
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..');
const out = path.join(root, 'www', 'lib');
fs.mkdirSync(out, { recursive: true });
const files = [
  ['jsqr/dist/jsQR.js', 'jsQR.js'],
  ['@zxing/library/umd/index.min.js', 'zxing.min.js'],
  ['qrcode-generator/qrcode.js', 'qrcode.js'],
];
let ok = true;
for (const [src, dst] of files) {
  const from = path.join(root, 'node_modules', src);
  if (!fs.existsSync(from)) { console.error('찾을 수 없음:', src); ok = false; continue; }
  fs.copyFileSync(from, path.join(out, dst));
  console.log('복사함:', dst);
}
if (!ok) process.exit(1);
