// 清理 CI 自动签名攒下来的开发证书。
//
// ## 为什么需要它
//
// `xcodebuild -allowProvisioningUpdates` 每次找不到可用证书就**新建一个**,
// 而 Apple 对开发证书有数量上限(实测 12)。攒满之后构建直接失败:
//
//   error: Choose a certificate to revoke. Your account has reached the
//          maximum number of certificates.
//   error: No profiles for 'com.lfm097384.lares' were found
//
// 第二条报错极具误导性 —— 看着像描述文件配置问题,实际根因是第一条。
// 2026-09-21 实测撞到:12 个全是 "Created via API"。
//
// ## 安全性
//
// 只吊销 **DEVELOPMENT 类型且名字含 "Created via API"** 的证书:
// - 不碰分发证书(DISTRIBUTION / DEVELOPER_ID_*)——那些签的是已上架的包
// - 不碰手工创建的开发证书(名字不含 Created via API)
// - 吊销开发证书**不影响任何已上传或已发布的构建**,
//   它们在归档时就已经签好了
//
// 默认保留最新的 N 个(见 KEEP),下次构建可以直接复用,不必再新建。
//
// ## 用法
//
//   ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_P8=<path> \
//     node scripts/asc-prune-certs.mjs [--dry-run]
//
// 依赖 jsonwebtoken(CI 里先 `npm install jsonwebtoken --no-save`)。
import fs from 'node:fs';
import jwt from 'jsonwebtoken';

const KEY_ID = process.env.ASC_KEY_ID;
const ISSUER = process.env.ASC_ISSUER_ID;
const P8 =
  process.env.ASC_P8 ??
  `${process.env.HOME ?? process.env.USERPROFILE}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`;

/// 保留几个最新的。留 2 个而不是 1 个:并发构建时两个 job 可能各要一张,
/// 只留 1 个会让其中一个又去新建,等于没清理。
const KEEP = Number(process.env.ASC_KEEP_CERTS ?? 2);
const DRY = process.argv.includes('--dry-run');

for (const [k, v] of Object.entries({ ASC_KEY_ID: KEY_ID, ASC_ISSUER_ID: ISSUER })) {
  if (!v) { console.error(`缺少环境变量 ${k}`); process.exit(2); }
}
if (!fs.existsSync(P8)) { console.error(`找不到私钥:${P8}`); process.exit(2); }

const pem = fs.readFileSync(P8, 'utf8');
const token = () =>
  jwt.sign({}, pem, {
    algorithm: 'ES256', issuer: ISSUER, expiresIn: '10m',
    audience: 'appstoreconnect-v1', header: { alg: 'ES256', kid: KEY_ID, typ: 'JWT' },
  });

const API = 'https://api.appstoreconnect.apple.com/v1';

const res = await fetch(`${API}/certificates?limit=200`, {
  headers: { Authorization: `Bearer ${token()}` },
});
if (!res.ok) {
  console.error(`列举证书失败 HTTP ${res.status}`);
  process.exit(1);
}
const { data = [] } = await res.json();

const byType = {};
for (const c of data) {
  const t = c.attributes.certificateType;
  byType[t] = (byType[t] ?? 0) + 1;
}
console.log(`证书总数 ${data.length}`);
for (const [t, n] of Object.entries(byType)) console.log(`  ${t}: ${n}`);

// 只碰 CI 自己造的开发证书
const candidates = data
  .filter(
    (c) =>
      c.attributes.certificateType === 'DEVELOPMENT' &&
      /Created via API/i.test(c.attributes.name ?? ''),
  )
  .sort((a, b) =>
    a.attributes.expirationDate.localeCompare(b.attributes.expirationDate),
  );

const toRevoke = candidates.slice(0, Math.max(0, candidates.length - KEEP));
console.log(
  `\nCI 开发证书 ${candidates.length} 个,保留最新 ${Math.min(KEEP, candidates.length)} 个,` +
    `待吊销 ${toRevoke.length} 个${DRY ? '(dry-run,不实际删除)' : ''}`,
);

if (!toRevoke.length) { console.log('无需清理。'); process.exit(0); }

let failed = 0;
for (const c of toRevoke) {
  const exp = c.attributes.expirationDate.slice(0, 10);
  if (DRY) { console.log(`  · ${c.id}  到期 ${exp}`); continue; }
  const r = await fetch(`${API}/certificates/${c.id}`, {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${token()}` },
  });
  console.log(`  ${r.ok ? '✓' : '✗'} ${c.id}  到期 ${exp}${r.ok ? '' : `  HTTP ${r.status}`}`);
  if (!r.ok) failed++;
}
process.exit(failed ? 1 : 0);
