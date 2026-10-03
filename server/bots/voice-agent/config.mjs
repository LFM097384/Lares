// AiVoiceConfig(CONTRACT.md §3)。规范实现在 server/src/ai_voice_config.js:
// 服务端 plugins.js 也要用它,而服务端镜像(server/Dockerfile)只 COPY src/ ——
// 放在 src/ 里,服务器就不依赖 bots/ 目录存在。这里原样转出,bot 侧照常 import './config.mjs'。
export * from '../../src/ai_voice_config.js';
