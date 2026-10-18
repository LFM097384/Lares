// Ember(炉灵,炉火之灵)· 公共 API。与平台无关:不依赖 Lares、LiveKit 或任何 npm 包。
// 平台插件实现 PORT.md 里的 port,然后 createEmber({port, llm, asr, memoryDir, policy})。
//
//   const ember = await createEmber({ port, llm, asr, memoryDir, policy: { k: 2, convenerId, scopeId } });
//   await ember.start();          // port.join() → 名单 → 会话开始(notifyHost {type:'active', on:true})
//   await ember.stop('stop');     // 散会:回执 → 清空 → port.leave()
//   const receipt = await ember.done;
import { EmberSession, wirePort, AGENT_NAME, AGENT_NAME_EN, ROLE_CHECK_PROMPT, GENERALISE_PROMPT } from './agent/session.mjs';
import { openMemory, wrapMemory } from './agent/memory_iface.mjs';
import { loadSkills, SKILLS_DIR, parseFrontMatter, ROUTER_PROMPT, heuristicRoute } from './agent/skills.mjs';

export { EmberSession, wirePort, AGENT_NAME, AGENT_NAME_EN, ROLE_CHECK_PROMPT, GENERALISE_PROMPT };
export { openMemory, wrapMemory, loadSkills, SKILLS_DIR, parseFrontMatter, ROUTER_PROMPT, heuristicRoute };
export { createIngestGate, stripPseudonyms } from './agent/ingest_gate.mjs';
export { SpeakerAsr } from './agent/asr.mjs';
export { MockAsr } from './agent/mock_asr.mjs';
export * as audio from './agent/audio.mjs';
export { seal, unseal, generateX25519, x25519RawPublic, x25519PublicFromRaw, SEAL_VERSION, SEAL_INFO_PREFIX } from './agent/sealing.mjs';
export { canonicalJSON, sha256hex, verifyEd25519, generateEd25519, signEd25519, rawPublicKeyB64, approvalMessage } from './core/crypto.mjs';
export { readReleasedKnowledge, createFileMemory } from './core/filememory.mjs';
export { createDeepSeekLLM, parseJSON, chatJSON } from './core/gate/llm.mjs';
export { NOTICE } from './core/gate/gate.mjs';
export { hasToneMarker } from './core/gate/l3.mjs';
export { checkPort, PORT_EVENTS } from './port.mjs';
import { checkPort } from './port.mjs';

/**
 * @param {object} o
 * @param {import('./port.mjs').EmberPort} o.port   平台插件(PORT.md)
 * @param {{chat(messages, opts): Promise<{text}>}|null} [o.llm]  null = 全确定性 mock 路径
 * @param {object|null} [o.asr]        ASR provider(open({identity,onFinal,…}));null = 不转写(只收 message)
 * @param {string|null} [o.memoryDir]  文件记忆目录;null = 内存记忆
 * @param {{k?: number, convenerId?: string, scopeId?: string}} [o.policy]
 *   k:放行门槛(缺省 = min(n, ⌈n/2⌉+1));convenerId:只有它能 end(缺省第一个进来的人);scopeId:记忆作用域(如圈 id)
 * 可选注入:memory / skills / log / emit / clock / onEnded(receipt) / sessionOpts(ingestOpts、asrOpts 等)
 *   autoLeave(缺省 true):会话自己结束(convener end / 最后一人离开)后 leaveDelayMs(300)再 port.leave(),留时间把 ended 送出去
 */
export async function createEmber({ port, llm = null, asr = null, memoryDir = null, policy = {}, memory, skills, log = () => {}, emit = () => {}, clock, onEnded, sessionOpts = {}, autoLeave = true, leaveDelayMs = 300 } = {}) {
  checkPort(port);
  const scopeId = policy.scopeId ?? null;
  let session = null;
  const mem = memory ?? await openMemory({ dir: memoryDir, circleId: scopeId, roster: () => session?.rosterFn() ?? [], log });
  const sk = skills ?? await loadSkills(undefined, { log });
  let resolveDone;
  let left = false;
  const leave = async () => { if (left) return; left = true; try { await port.leave(); } catch { /* */ } };
  const done = new Promise((r) => { resolveDone = r; });
  session = new EmberSession({
    scopeId, selfId: port.selfId, isHuman: (id) => (typeof port.isHuman === 'function' ? port.isHuman(id) : true),
    llm, asr, memory: mem, skills: sk, k: policy.k ?? null, convenerId: policy.convenerId ?? null, log, emit,
    ...(clock ? { clock } : {}),
    transport: {
      broadcast: (obj) => port.send(obj),
      sendTo: (id, obj) => port.send(obj, id),
      notifyHost: (ev) => port.notifyHost(ev),
    },
    onEnded: async (receipt) => {
      resolveDone(receipt);
      if (autoLeave) setTimeout(() => { void leave(); }, leaveDelayMs).unref?.();
      await onEnded?.(receipt);
    },
    ...sessionOpts,
  });
  wirePort(session, port);
  return {
    session, memory: mem, skills: sk, done,
    get ended() { return session.ended; },
    async start() {
      await port.join();
      for (const p of port.participants?.() ?? []) session.participantJoined(p.id, p.name);
      session.start();
      return this;
    },
    async stop(why = 'stop') {
      try { await session.end(why); } catch { /* */ }
      await leave();
      return session.receipt;
    },
    leave,
  };
}
