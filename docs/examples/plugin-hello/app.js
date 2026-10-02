// Lares 插件示例:plain JS,不需要构建。
// 只用 window.lares 桥(见 docs/plugin-api.md §8),所有方法都返回 Promise。
(function () {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };

  function log(text, isError) {
    var li = document.createElement('li');
    li.textContent = new Date().toLocaleTimeString() + '  ' + text;
    if (isError) li.className = 'err';
    var ol = $('log');
    ol.insertBefore(li, ol.firstChild);
    while (ol.children.length > 50) ol.removeChild(ol.lastChild);
  }

  function describe(err) {
    return (err && err.code ? '[' + err.code + '] ' : '') + (err && err.message ? err.message : String(err));
  }

  // 没有桥(在普通浏览器里打开)→ 提示并退出。
  if (!window.lares) {
    $('absent').style.display = 'block';
    return;
  }
  var lares = window.lares;
  $('app').hidden = false;

  var members = new Map();   // userId → {userId, name, status}
  var counter = 0;
  var nickname = '';

  function renderMembers() {
    var ul = $('members');
    ul.textContent = '';
    if (members.size === 0) {
      var empty = document.createElement('li');
      empty.className = 'muted';
      empty.textContent = '(没人)';
      ul.appendChild(empty);
      return;
    }
    members.forEach(function (m) {
      var li = document.createElement('li');
      li.textContent = (m.name || m.userId) + (m.status ? '  · ' + m.status : '');
      ul.appendChild(li);
    });
  }

  function renderState(state, rev) {
    counter = state && typeof state.counter === 'number' ? state.counter : 0;
    $('counter').textContent = String(counter);
    $('rev').textContent = rev != null ? 'rev ' + rev : '';
  }

  function renderTitle() {
    $('title').textContent = nickname ? 'Hello, ' + nickname : 'Hello';
  }

  async function init() {
    // 圈子
    try {
      var c = await lares.getCircle();
      $('circle').textContent = 'id ' + c.id + (c.e2ee ? ' · 端到端加密' : '');
      $('circle').className = '';
    } catch (e) {
      $('circle').textContent = '读不到圈子信息:' + describe(e);
    }

    // 成员与自己
    try {
      var list = await lares.getMembers();
      (list || []).forEach(function (m) { members.set(m.userId, m); });
      renderMembers();
      var me = await lares.getSelf();
      log('我是 ' + (me.name || me.userId));
    } catch (e) {
      log('读成员失败:' + describe(e), true);
    }

    // 本机存储:昵称
    try {
      nickname = (await lares.storage.get('nickname')) || '';
      $('nick').value = nickname;
      renderTitle();
    } catch (e) {
      log('读本机存储失败:' + describe(e), true);
    }

    // 共享状态
    try {
      var s = await lares.getState();
      renderState(s.state, s.rev);
    } catch (e) {
      log('读共享状态失败:' + describe(e), true);
    }

    // 事件订阅
    lares.on('state', function (ev) {
      renderState(ev.state, ev.rev);
      log('共享状态更新 → counter=' + counter + ' (rev ' + ev.rev + ')');
    });
    lares.on('join', function (m) {
      members.set(m.userId, m);
      renderMembers();
      log((m.name || m.userId) + ' 进房了');
    });
    lares.on('leave', function (m) {
      members.delete(m.userId);
      renderMembers();
      log((m.name || m.userId) + ' 离开了');
    });
    lares.on('caption', function (c) {
      if (c.final) log('字幕 ' + (c.name || '') + ':' + c.text);
    });
  }

  async function setCounter(n) {
    try {
      // JSON Merge Patch:只改 counter,其他键不动。
      var r = await lares.setState({ counter: n });
      log('已写入 counter=' + n + ' (rev ' + r.rev + ')');
    } catch (e) {
      log('写共享状态失败:' + describe(e), true);
    }
  }

  $('inc').addEventListener('click', function () { setCounter(counter + 1); });
  $('reset').addEventListener('click', function () { setCounter(0); });

  $('saveNick').addEventListener('click', async function () {
    var v = $('nick').value.trim();
    try {
      await lares.storage.set('nickname', v || null);   // null = 删除
      nickname = v;
      renderTitle();
      log(v ? '记住了昵称:' + v : '已清除昵称');
    } catch (e) {
      log('保存昵称失败:' + describe(e), true);
    }
  });

  $('hello').addEventListener('click', async function () {
    try {
      await lares.sendChat(nickname ? '你好,我是 ' + nickname + ' 👋' : '你好 👋');
      log('已发送聊天');
    } catch (e) {
      log('发聊天失败:' + describe(e), true);
    }
  });

  init().catch(function (e) { log('初始化失败:' + describe(e), true); });
})();
