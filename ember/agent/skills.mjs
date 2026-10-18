// 隐名之约 v2 · skills 加载器(AGENT-V2.md §6)。
// 目录:ember/skills/<name>/SKILL.md(front-matter:name / description / outputs: room|release)+ run.mjs。
//
// run.mjs 导出 default async function run(ctx) —— ctx 是**唯一**能拿到的东西:
//   ctx.ledger   只读访问器 { entries(), text({maxChars}), size }(已脱敏、带假名;没有原话 / 映射 / 名单)
//   ctx.memory   { recall(q,{limit}) }(只读)
//   ctx.llm      { chat(messages, opts) } —— 经守卫包装:每条消息先过 L1/L2(名单名字进不了 LLM)
//   ctx.q / ctx.args / ctx.lang
// 返回:outputs=room → { text };outputs=release → { items:[{topic, kind, text, flags?}] }
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const SKILLS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'skills');
const NAME_RE = /^[a-z][a-z0-9_-]{0,31}$/;

export function parseFrontMatter(src) {
  const m = String(src).match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { meta: {}, body: String(src) };
  const meta = {};
  for (const line of m[1].split(/\r?\n/)) {
    const kv = line.match(/^([A-Za-z_][\w-]*)\s*:\s*(.*)$/);
    if (kv) meta[kv[1]] = kv[2].trim().replace(/^["']|["']$/g, '');
  }
  return { meta, body: m[2] };
}

export async function loadSkills(dir = SKILLS_DIR, { log = () => {} } = {}) {
  const out = new Map();
  if (!existsSync(dir)) return out;
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    if (!ent.isDirectory()) continue;
    const base = path.join(dir, ent.name);
    const mdPath = path.join(base, 'SKILL.md');
    const runPath = path.join(base, 'run.mjs');
    if (!existsSync(mdPath) || !existsSync(runPath)) continue;
    const { meta, body } = parseFrontMatter(readFileSync(mdPath, 'utf8'));
    const name = String(meta.name ?? ent.name);
    if (!NAME_RE.test(name) || !['room', 'release'].includes(meta.outputs)) { log(`skill ${ent.name}: SKILL.md front-matter 不合法,跳过`); continue; }
    try {
      const mod = await import(pathToFileURL(runPath).href);
      const run = mod.default ?? mod.run;
      if (typeof run !== 'function') throw new Error('no run()');
      out.set(name, Object.freeze({ name, description: String(meta.description ?? ''), outputs: meta.outputs, instructions: body.trim(), run }));
    } catch (e) { log(`skill ${name} 加载失败: ${e.message}`); }
  }
  return out;
}

/// 路由提示:只给 LLM skill 名 + 描述 + 已脱敏的问题
export const ROUTER_PROMPT = (skills) => `You route a meeting participant's request to one skill of an anonymised meeting assistant.
Skills:
${[...skills.values()].map((s) => `- ${s.name}: ${s.description}`).join('\n')}
Pick "minutes" only when the user asks to produce / export meeting minutes, a summary document, notes or a digest to take away; otherwise "answer".
Output only JSON: {"skill":"<name>"}`;

export function heuristicRoute(q, skills) {
  if (skills.has('minutes') && /纪要|会议记录|会议总结|出个总结|导出|minutes|meeting notes|write[- ]?up|digest/i.test(String(q))) return 'minutes';
  return skills.has('answer') ? 'answer' : [...skills.keys()][0] ?? null;
}
