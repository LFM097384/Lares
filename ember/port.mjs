// Ember 平台 port(规格见 PORT.md)。平台插件(Lares / Zoom / Teams …)实现这个形状,Ember 只经它碰外部世界。
//
/**
 * @typedef {object} EmberPort
 * @property {string} selfId                              Ember 在该平台上的身份(自己的事件一律忽略)
 * @property {(id: string) => boolean} [isHuman]          该身份是不是真人(机器人 / 其他 AI 返回 false;缺省全当真人)
 * @property {(event: string, fn: Function) => any} on   订阅事件,见 PORT_EVENTS
 * @property {() => Array<{id: string, name: string}>} participants   当前在场的人(join 之后调用)
 * @property {(id: string) => string} [nameOf]            显示名(仅内存,不出进程)
 * @property {(obj: object, toId?: string|null) => Promise<void>|void} send   消息通道:广播,或只发给 toId
 * @property {(event: {type: 'active', on: boolean} | {type: 'released', itemIds: string[]}) => Promise<void>|void} notifyHost
 *   通知宿主平台(只有元数据,绝无会话文字):会话开关(宿主据此关转写 / 录音 / 其它机器人)与「有条目放行了」
 * @property {() => Promise<any>} join                    生命周期:进会
 * @property {() => Promise<void>} leave                  生命周期:离会(幂等)
 * @property {boolean} [transcripts]                      true = 平台直接给带说话人的定稿转写,经 'transcript' 事件进 IngestGate(同 ASR 定稿)
 */

/** 事件:
 *   'joined'       (id, name?)                         有人进来
 *   'left'         (id)                                有人离开
 *   'name'         (id, name)                          得知 / 更新显示名
 *   'audio'        (id, Int16Array pcm, sampleRate, channels)   该参与者的一帧音频(逐人分轨)
 *   'message'      (id, obj)                           该参与者发来的一条会话协议消息(已 JSON 解析)
 *   'disconnected' (reason)                            平台连接断了(Ember 不处理;插件决定退出码)
 *   'transcript'   (id, text)                          可选,仅当 port.transcripts === true:该参与者一句定稿转写(平台侧 ASR)。
 *                                                      与音频同一道门:未 ack 的丢弃,其余立即过 IngestGate,原话不留引用
 */
export const PORT_EVENTS = Object.freeze(['joined', 'left', 'name', 'audio', 'message', 'disconnected']);
export const OPTIONAL_PORT_EVENTS = Object.freeze(['transcript']);

const REQUIRED = ['on', 'send', 'notifyHost', 'join', 'leave', 'participants'];

/// 形状检查(createEmber 调用):缺方法直接抛,别等到会上才发现
export function checkPort(port) {
  if (!port || typeof port !== 'object') throw new TypeError('ember: port is required');
  if (typeof port.selfId !== 'string' || !port.selfId) throw new TypeError('ember: port.selfId must be a non-empty string');
  const missing = REQUIRED.filter((k) => typeof port[k] !== 'function');
  if (missing.length) throw new TypeError(`ember: port is missing ${missing.join(', ')}`);
  return port;
}
