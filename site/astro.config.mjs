// @ts-check
import { defineConfig } from 'astro/config';

// Lares 炉灵 官网
//
// 三条硬约束，改这个文件前先读 docs/design/web-brief.md：
//
// 1. 纯静态 + 目录式路由。ASC 里填的是 /privacy /terms /support，
//    没有 .html 后缀，审核员会点。format: 'directory' 保证
//    src/pages/privacy.md -> dist/privacy/index.html
// 2. 零客户端 JS。Astro 默认就不发 JS（没有 client:* 指令时），
//    不要引入任何带 hydration 的集成。
// 3. 零第三方请求。隐私政策写着「不收集」，站点必须做到。
//    inlineStylesheets: 'always' 把 CSS 直接内联进 HTML，
//    连同域的额外 CSS 请求都没有 —— 整站每页只有 1 个 document 请求。
export default defineConfig({
  site: 'https://docs.laresapp.org',
  output: 'static',
  trailingSlash: 'ignore',
  compressHTML: true,
  build: {
    format: 'directory',
    inlineStylesheets: 'always',
  },
  devToolbar: {
    // 开发工具栏会注入客户端脚本。本站的纪律是零 JS，
    // 关掉它以免开发时的观感与产物不一致。
    enabled: false,
  },
  markdown: {
    // 语法高亮会生成大量内联样式，本站正文没有代码块，关掉。
    syntaxHighlight: false,
  },
});
