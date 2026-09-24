// 轮询 App Store Connect,等某个 build number 的处理结果。
//
// ## 为什么需要它
//
// `altool` **只报送达,不报处理结果**。2026-09-19 实测:连续两次返回
// `"No errors uploading"`、带 delivery-uuid、32MB 确实传到了 Apple,
// 但构建**从未出现**在 TestFlight —— 没有邮件,没有界面提示,
// `GET /v1/builds` 返回空数组。
//
// 真正的原因(ITMS-90683,缺 NSCameraUsageDescription)只存在于
// REST API 的 `GET /v1/buildUploads/<id>` 的 `state.errors` 里。
//
// 所以 CI 不能信 altool 的退出码。这个脚本轮询到 VALID 才算成功。
//
// ## 用法
//
//   ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_P8=<path> BUILD_NUMBER=42 \
//     node scripts/asc-wait-build.mjs
//
// 依赖 jsonwebtoken。CI 里先 `npm install jsonwebtoken --no-save`。
//
// 退出码:0=VALID(可用) 1=INVALID/FAILED(被拒) 2=参数缺失 3=超时未出结果
import fs from 'node:fs';
import jwt from 'jsonwebtoken';

const KEY_ID = process.env.ASC_KEY_ID;
const ISSUER = process.env.ASC_ISSUER_ID;
const WANT = process.env.BUILD_NUMBER;
const P8 =
  process.env.ASC_P8 ??
  `${process.env.HOME ?? process.env.USERPROFILE}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`;

// 最多等多久。处理通常 5–30 分钟,这里给 20 分钟。
const MAX_MINUTES = Number(process.env.ASC_WAIT_MINUTES ?? 20);
const INTERVAL_MS = 30_000;

for (const [k, v] of Object.entries({ ASC_KEY_ID: KEY_ID, ASC_ISSUER_ID: ISSUER, BUILD_NUMBER: WANT })) {
  if (!v) {
    console.error(`缺少环境变量 ${k}`);
    process.exit(2);
  }
}
if (!fs.existsSync(P8)) {
  console.error(`找不到私钥:${P8}`);
  process.exit(2);
}

const pem = fs.readFileSync(P8, 'utf8');

// JWT 最长 20 分钟,轮询可能超过,所以每次现签一个短的。
function token() {
  return jwt.sign({}, pem, {
    algorithm: 'ES256',
    issuer: ISSUER,
    expiresIn: '10m',
    audience: 'appstoreconnect-v1',
    header: { alg: 'ES256', kid: KEY_ID, typ: 'JWT' },
  });
}

async function get(path) {
  const r = await fetch('https://api.appstoreconnect.apple.com/v1' + path, {
    headers: { Authorization: `Bearer ${token()}` },
  });
  if (!r.ok) {
    console.log(`  (HTTP ${r.status},稍后重试)`);
    return null;
  }
  return r.json();
}

// 把 buildUploads 里的错误打出来 —— 这是唯一能看到 ITMS-9xxxx 的地方
async function reportUploadErrors() {
  const j = await get('/buildUploads?limit=10');
  if (!j?.data?.length) return;
  for (const u of j.data) {
    const a = u.attributes ?? {};
    if (a.cfBundleVersion !== WANT) continue;
    const st = a.state ?? {};
    console.log(`\n  buildUpload ${u.id}  state=${st.state}`);
    for (const e of st.errors ?? []) {
      console.log(`    ✗ [${e.code}] ${e.description}`);
    }
    for (const w of st.warnings ?? []) {
      console.log(`    ⚠ [${w.code}] ${w.description?.slice(0, 200)}`);
    }
  }
}

// 出口合规:Info.plist 刻意不写 ITSAppUsesNonExemptEncryption(见 docs/compliance/encryption-export.md),
// 于是每个构建 VALID 后都卡在 MISSING_EXPORT_COMPLIANCE,测试员看不到。2026-09-23 实测
// build 37/38 因此没进 TestFlight。build 36 的网页问卷答完后 ASC 记为 usesNonExemptEncryption=false
// (5D992.c 大众市场自分类 → 不属于「需申报」的加密),这里对新构建给出同一个答案。
// 已经答过的不动;失败只警告,不让整个上传判失败。
async function answerExportCompliance(buildId) {
  const j = await get(`/builds/${buildId}?fields[builds]=usesNonExemptEncryption`);
  const cur = j?.data?.attributes?.usesNonExemptEncryption;
  if (cur !== null && cur !== undefined) {
    console.log(`  出口合规已答(usesNonExemptEncryption=${cur}),不动`);
    return;
  }
  const r = await fetch(`https://api.appstoreconnect.apple.com/v1/builds/${buildId}`, {
    method: 'PATCH',
    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      data: { type: 'builds', id: buildId, attributes: { usesNonExemptEncryption: false } },
    }),
  });
  if (r.ok) console.log('  ✓ 出口合规已按 build 36 的答案填好,测试员可见');
  else console.log(`::warning::出口合规自动填写失败(HTTP ${r.status}),需到 ASC 网页手动答问卷`);
}

const rounds = Math.ceil((MAX_MINUTES * 60_000) / INTERVAL_MS);
console.log(`等待 build ${WANT} 处理完成(最多 ${MAX_MINUTES} 分钟)`);

for (let i = 1; i <= rounds; i++) {
  const j = await get(
    '/builds?limit=20&sort=-uploadedDate&fields[builds]=version,processingState,uploadedDate',
  );
  const b = j?.data?.find((x) => x.attributes?.version === WANT);

  if (b) {
    const st = b.attributes.processingState;
    console.log(`[${i}/${rounds}] build ${WANT} → ${st}`);
    if (st === 'VALID') {
      await answerExportCompliance(b.id);
      console.log('\n✓ 构建可用,TestFlight 里能看到了');
      process.exit(0);
    }
    if (st === 'INVALID' || st === 'FAILED') {
      console.log(`\n::error::构建被判为 ${st}`);
      await reportUploadErrors();
      process.exit(1);
    }
  } else {
    console.log(`[${i}/${rounds}] 还没出现 build ${WANT}...`);
    // 没出现也可能是已经被判失败后丢弃了,顺手查一眼上传批次
    if (i === 4 || i === 12) await reportUploadErrors();
  }

  if (i < rounds) await new Promise((s) => setTimeout(s, INTERVAL_MS));
}

console.log(`\n::warning::${MAX_MINUTES} 分钟内没等到结果。可能只是慢,也可能被静默丢弃。`);
await reportUploadErrors();
process.exit(3);
