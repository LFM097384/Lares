// ember-desk · /ui 静态状态页。不含任何数据;token 从 location.hash 读(/ui#<token>),带 bearer 调 API。
// 所有动态内容用 textContent 写入,不用 innerHTML。
export const UI_HTML = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>炉灵 · 状态</title>
<style>
:root{color-scheme:light dark;--a:#d9631e;--bg:#faf7f4;--fg:#222;--mut:#777;--card:#fff;--bd:#e6ddd4}
@media (prefers-color-scheme:dark){:root{--bg:#1c1917;--fg:#eee;--mut:#9a948e;--card:#28231f;--bd:#3a332d}}
*{box-sizing:border-box}body{margin:0;font:14px/1.5 "Microsoft YaHei UI","PingFang SC",system-ui,sans-serif;background:var(--bg);color:var(--fg)}
header{padding:14px 20px;border-bottom:1px solid var(--bd);display:flex;gap:12px;align-items:center}
h1{font-size:18px;margin:0;color:var(--a)}#state{padding:2px 10px;border-radius:10px;background:var(--bd);font-size:12px}
main{max-width:920px;margin:0 auto;padding:16px;display:grid;gap:14px}
section{background:var(--card);border:1px solid var(--bd);border-radius:10px;padding:12px 16px}
h2{font-size:14px;margin:0 0 8px;color:var(--mut);font-weight:600}
table{width:100%;border-collapse:collapse}td{padding:5px 6px;border-top:1px solid var(--bd);vertical-align:top}
.mut{color:var(--mut);font-size:12px}button{cursor:pointer;border:1px solid var(--bd);background:var(--bg);color:var(--fg);border-radius:6px;padding:4px 10px}
button.p{background:var(--a);color:#fff;border-color:var(--a)}input{width:100%;padding:6px 8px;border:1px solid var(--bd);border-radius:6px;background:var(--bg);color:var(--fg)}
.row{display:flex;gap:8px;align-items:center}.row input{flex:1}#feed div{padding:5px 0;border-top:1px solid var(--bd)}#err{color:#c0392b}
</style></head><body>
<header><h1>炉灵</h1><span id="state">连接中…</span><span class="mut" id="ver"></span></header>
<main>
<section><h2>会议</h2><div id="sess" class="mut">无活动会议</div>
<div class="row" style="margin-top:8px"><input id="link" placeholder="粘贴 Jitsi 会议链接 https://主机/房间名" maxlength="2048"><button class="p" id="join">加入</button><button id="leave">离会</button></div>
<div id="err"></div></section>
<section><h2>提问</h2><div class="row"><input id="q" placeholder="问炉灵一个问题(只在本机)" maxlength="8000"><button id="ask">提问</button></div><div id="ans" style="margin-top:6px;white-space:pre-wrap"></div></section>
<section><h2>通道</h2><table id="ch"></table></section>
<section><h2>最近消息</h2><div id="feed"></div></section>
</main>
<script>
(function(){
var token=decodeURIComponent((location.hash||'').slice(1));
var $=function(id){return document.getElementById(id)};
var STATE={idle:'空闲',joining:'进会中',"in-meeting":'会议中',leaving:'离会中'};
function api(m,p,b){var h={Authorization:'Bearer '+token};if(b){h['Content-Type']='application/json'}
 return fetch(p,{method:m,headers:h,body:b?JSON.stringify(b):undefined}).then(function(r){return r.json().then(function(j){if(!r.ok)throw new Error(j.message||j.error||r.status);return j})})}
function el(t,txt,cls){var e=document.createElement(t);if(txt!=null)e.textContent=txt;if(cls)e.className=cls;return e}
function render(s){$('state').textContent=STATE[s.state]||s.state;$('ver').textContent='v'+s.version+' · pid '+s.pid;
 var x=s.session||s.lastSession;$('sess').textContent=x?((s.session?'当前':'上次')+':'+x.adapter+' '+(x.room||'')+' · '+x.state+(x.error?' · '+x.error:'')):'无活动会议';
 var t=$('ch');t.textContent='';(s.channels||[]).forEach(function(c){var tr=el('tr');tr.appendChild(el('td',c.name));
  var d=el('td');d.appendChild(el('div',(c.running?'运行中':'未运行')+(c.configured?'':' · 未配置')+(c.enabled?' · 自启':''),'mut'));d.appendChild(el('div',c.detail,'mut'));tr.appendChild(d);
  var b=el('td');if(c.kind!=='meeting'&&c.configured){var btn=el('button',c.running?'停止':'启动');btn.onclick=function(){api('POST','/channels/'+c.id+'/'+(c.running?'stop':'start')).then(refresh,showErr)};b.appendChild(btn)}
  tr.appendChild(b);t.appendChild(tr)})}
function feed(){api('GET','/feed?n=30').then(function(items){var f=$('feed');f.textContent='';items.slice().reverse().forEach(function(i){var d=el('div');d.appendChild(el('span',new Date(i.at).toLocaleString()+' ','mut'));d.appendChild(el('b',i.title+' '));d.appendChild(el('span',i.text));f.appendChild(d)})},showErr)}
function showErr(e){$('err').textContent=String(e&&e.message||e)}
function refresh(){api('GET','/status').then(render,showErr);feed()}
$('join').onclick=function(){$('err').textContent='';api('POST','/join',{link:$('link').value.trim()}).then(refresh,showErr)};
$('leave').onclick=function(){api('POST','/leave',{}).then(refresh,showErr)};
$('ask').onclick=function(){$('ans').textContent='思考中…';api('POST','/ask',{text:$('q').value}).then(function(r){$('ans').textContent=r.answer;feed()},function(e){$('ans').textContent='';showErr(e)})};
if(!token){showErr('缺少 token:请从托盘打开状态页');return}
refresh();setInterval(refresh,5000);
})();
</script></body></html>`;
