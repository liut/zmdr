---
date: 2026-06-01
topic: math-formula-rendering
---

# Math Formula Rendering

## Summary

自动识别 Markdown 中的 LaTeX 数学公式——块级 `$$...$$` 和行内 `$...$`——通过 KaTeX 渲染为排版公式。

---

## Problem Frame

zmdr 当前无法渲染数学公式。用户编写包含矩阵、分段函数、群论符号等 LaTeX 公式的 Markdown 文档时，`$$...$$` 和 `$...$` 块被 marked.js 当作普通文本处理，显示为原始 LaTeX 源码，完全不可读。

常见的数学写作场景包括线性代数（矩阵）、数学分析（分段函数）、抽象代数（群/环/域符号），这些在当前 zmdr 中都不可用。

---

## Requirements

### 公式识别

- R1. 识别 `$$...$$` 块级公式，渲染为 KaTeX display mode 居中排版公式
- R2. 识别 `$...$` 行内公式，渲染为 KaTeX inline mode 公式，与周围文字基线对齐
- R3. `$` 后紧跟数字（如 `$100`）或空白字符时，不触发公式渲染，视为普通文本

### 渲染

- R4. 使用 KaTeX 渲染，CSS 和 JS 从 CDN 加载
- R5. 渲染失败时显示错误提示，使用 `.math-error` 样式类，不崩溃
- R6. 公式在深色/浅色系统主题下均可读

### 兼容性

- R7. 公式渲染不破坏现有功能：代码语法高亮、Mermaid 图表、TOC 生成、搜索高亮

---

## Acceptance Examples

- AE1. **Covers R1.** Given markdown 包含 `$$\begin{bmatrix} a & b \\ c & d \end{bmatrix}$$`，渲染为居中的块级矩阵公式
- AE2. **Covers R2.** Given `$\left<\mathbb{Z}_6,+_{\bmod}\right>$ 的生成元是 $\{1,5\}$`，两个行内公式分别渲染为排版数学符号，普通中文文字保持不变
- AE3. **Covers R1, R2.** Given `$$a^n=\left\{ \begin{array}{c} e & n=0\\ a^{n-1}a & n>0\\ \left( a^{-1} \right)^m & n<0,n=-m \end{array} \right.$$`，渲染为多行分段函数公式
- AE4. **Covers R3.** Given `价格 $100 和 $50`，`$100` 和 `$50` 不触发公式渲染
- AE5. **Covers R5.** Given `$$\invalid{$$`，显示错误提示（如 "Formula error: ..."）而非白屏
- AE6. **Covers R7.** 包含 `$$` 公式 + Mermaid 图 + 代码块 + TOC 的文档，四项功能均正确渲染

---

## Success Criteria

- 用户打开包含 LaTeX 公式的 .md 文件，公式以排版形式呈现而非原始 TeX 源码
- 行内公式与周围文字基线对齐，不破坏段落排版
- 与现有 Mermaid、代码高亮、TOC、搜索功能无冲突

---

## Scope Boundaries

- 不支持 `\(...\)` / `\[...\]` LaTeX 定界符
- 不修改 Zig 后端（纯前端改动，assets/index.html）

---

## Technical Approaches

以下两个方案在需求层面等效，最终选型在规划阶段根据集成复杂度决定：

### 方案 A：预处理替换

marked.parse() 之前，正则匹配 `$$...$$` / `$...$` 并替换为 HTML 占位符，标记渲染后调用 `katex.renderToString()` 替换占位符内容。

- 优点：与现有 Mermaid 后处理模式一致，marked.js 升级不耦合
- 风险：两步处理，需保证占位符不被 marked.js 转义

### 方案 B：marked.js 自定义扩展

注册 marked.js custom tokenizer + renderer，在解析阶段识别 `$$` / `$` token，renderer 内同步调用 `katex.renderToString()` 产出最终 HTML。

- 优点：单遍处理，解析和渲染一体，代码更集中
- 风险：与 marked.js 内部 tokenizer 耦合，版本升级可能断裂；极端情况下大量公式同步渲染可能阻塞 UI

---

## Dependencies / Assumptions

- KaTeX CDN (jsDelivr) 可用
- 用户文档中的 `$` 符号遵循数学写作惯例（`$` 后紧跟非数字、非空白字符时表示公式开始）

---

## Outstanding Questions

### Deferred to Planning

- [Affects R1, R2][Technical] 正则匹配 `$` 的精确规则需在实现时细化（`$` 前后的字符上下文判断，如 `$` 前不能是 `\` 转义符）
- [Affects R1, R2][Technical] 方案 A vs B 选型：根据 marked.js 版本和 KaTeX API 的实际集成复杂度决定
