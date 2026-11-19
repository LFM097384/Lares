// ember-meet · 页面内只读探针(注入到会议网页;夹具测试同样用它)。
// 只读 DOM,不改页面、不发网络请求、不往 console 打印任何会议内容。
// window.__emberMeet.captions(sel) → { present, items:[{key, speaker, text}] }   文档顺序;author 与 text 按顺序配对
// window.__emberMeet.chat(sel)     → { present, items:[{key, author, text, mine}] }
// window.__emberMeet.roster(sel)   → [name]
// key:优先用平台自己的稳定 id(data-mid / id),否则给 DOM 节点分一个会话内编号(WeakMap)。
(() => {
  if (window.__emberMeet) return;
  let seq = 0;
  const ids = new WeakMap();
  const idOf = (el) => { let v = ids.get(el); if (!v) { seq += 1; v = `n${seq}`; ids.set(el, v); } return v; };
  const txt = (el) => (el ? String(el.textContent ?? '') : '').replace(/[\u200b\ufeff]/g, '').replace(/\s+/g, ' ').trim();
  const safe = (fn, fallback) => { try { return fn(); } catch { return fallback; } };

  function captions(sel) {
    return safe(() => {
      const wrapper = document.querySelector(sel.wrapper);
      if (!wrapper) return { present: false, items: [] };
      const items = [];
      let speaker = '';
      for (const el of wrapper.querySelectorAll(`${sel.author}, ${sel.text}`)) {
        if (el.matches(sel.author)) { speaker = txt(el); continue; }
        const text = txt(el);
        if (text) items.push({ key: el.getAttribute('data-caption-id') || idOf(el), speaker, text });
      }
      return { present: true, items };
    }, { present: false, items: [] });
  }

  function chat(sel) {
    return safe(() => {
      const list = document.querySelector(sel.list);
      if (!list) return { present: false, items: [] };
      const items = [];
      let author = '';
      let mine = false;
      for (const m of list.querySelectorAll(sel.message)) {
        const a = txt(m.querySelector(sel.author));
        const isMine = m.matches(sel.mine) || Boolean(m.querySelector(sel.mine));
        if (a) { author = a; mine = isMine; } else if (isMine) { author = ''; mine = true; }
        const body = m.querySelector(sel.body);
        const text = txt(body);
        if (!text) continue;
        const key = m.getAttribute('data-mid') || (body && body.id) || m.id || idOf(m);
        items.push({ key, author: isMine ? '' : author, text, mine: isMine || (!a && mine) });
      }
      return { present: true, items };
    }, { present: false, items: [] });
  }

  function roster(sel) {
    return safe(() => [...document.querySelectorAll(sel.item)].map((it) => txt(it.querySelector(sel.name)) || it.getAttribute('aria-label') || '').filter(Boolean), []);
  }

  /// 开关状态:true = 开,false = 关,null = 看不出
  function switchState(el) {
    if (!el) return null;
    if (el.type === 'checkbox') return Boolean(el.checked);
    const ac = el.getAttribute('aria-checked') ?? el.getAttribute('aria-pressed');
    if (ac === 'true' || ac === 'false') return ac === 'true';
    const label = `${el.getAttribute('aria-label') ?? ''} ${el.getAttribute('title') ?? ''}`;
    if (/turn (?:off|camera off|video off)|^\s*mute|关闭(?:摄像头|视频)|静音(?!解除)/i.test(label)) return true;
    if (/turn (?:on|camera on|video on)|unmute|打开(?:摄像头|视频)|取消静音|解除静音/i.test(label)) return false;
    return null;
  }

  Object.defineProperty(window, '__emberMeet', { value: Object.freeze({ captions, chat, roster, switchState, version: 1 }), configurable: false, enumerable: false });
})();
