// 仅供 `node --test hearthvoice-lares/`:Node 24 把目录参数当模块解析(无 main → index.js),这里转去导入 test/ 下全部 *.test.mjs。
// 公共 API 在 index.mjs;别从这里 import。
await import('./test/index.js');
