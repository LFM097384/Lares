import fs from 'node:fs';
import jwt from 'jsonwebtoken';

const KEY_ID = process.env.ASC_KEY_ID;
const ISSUER = process.env.ASC_ISSUER_ID;
const P8 = process.env.USERPROFILE + '\\.agent-memory\\_secrets\\AuthKey_' + KEY_ID + '.p8';
const APP_ID = process.env.ASC_APP_ID ?? '';

const token = jwt.sign({}, fs.readFileSync(P8, 'utf8'), {
  algorithm: 'ES256', issuer: ISSUER, expiresIn: '10m',
  audience: 'appstoreconnect-v1', header: { alg: 'ES256', kid: KEY_ID, typ: 'JWT' },
});
const H = { Authorization: `Bearer ${token}` };

async function get(p) {
  const r = await fetch('https://api.appstoreconnect.apple.com/v1' + p, { headers: H });
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, j };
}

// 1. 不带 app 过滤,看整个团队有没有任何构建(排除过滤条件写错)
const all = await get('/builds?limit=20&sort=-uploadedDate&fields[builds]=version,processingState,uploadedDate');
console.log('=== 团队全部构建 ===');
if (all.ok) {
  if (!all.j.data.length) console.log('  (空)');
  all.j.data.forEach(b => console.log(`  ${b.attributes.version}  ${b.attributes.processingState}  ${b.attributes.uploadedDate}`));
} else console.log('  HTTP ' + all.status);

// 2. preReleaseVersions —— TestFlight 的版本容器
const pre = await get(`/preReleaseVersions?filter[app]=${APP_ID}&limit=10&fields[preReleaseVersions]=version,platform`);
console.log('\n=== preReleaseVersions (TestFlight 版本) ===');
if (pre.ok) {
  if (!pre.j.data.length) console.log('  (空 —— ASC 从未为这个 App 建过任何 TestFlight 版本)');
  pre.j.data.forEach(v => console.log(`  ${v.attributes.version}  ${v.attributes.platform}`));
} else console.log('  HTTP ' + pre.status);

// 3. App 的版本与状态
const vers = await get(`/apps/${APP_ID}/appStoreVersions?limit=5&fields[appStoreVersions]=versionString,appStoreState,platform,createdDate`);
console.log('\n=== appStoreVersions ===');
if (vers.ok) {
  if (!vers.j.data.length) console.log('  (空)');
  vers.j.data.forEach(v => console.log(`  ${v.attributes.versionString}  ${v.attributes.appStoreState}  ${v.attributes.platform}`));
} else console.log('  HTTP ' + vers.status);

// 4. 协议状态 —— 未签协议会让构建无法处理
const agr = await get('/agreements?limit=10');
console.log('\n=== agreements ===');
console.log(agr.ok ? JSON.stringify(agr.j.data?.map(a => a.attributes) ?? [], null, 2).slice(0, 600) : 'HTTP ' + agr.status + ' (该端点可能不可用)');
