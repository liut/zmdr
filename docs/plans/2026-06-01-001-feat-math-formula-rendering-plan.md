---
date: 2026-06-01
type: feat
topic: math-formula-rendering
status: completed
origin: docs/brainstorms/2026-06-01-math-formula-rendering-requirements.md
---

# feat: Math Formula Rendering with KaTeX

## Summary

Add KaTeX-based LaTeX math formula rendering to zmdr's markdown pipeline. Block formulas (`$$...$$`) render as centered display math, inline formulas (`$...$`) render as inline math. Implemented via marked.js custom extensions — a block-level extension for `$$...$$` and an inline-level extension for `$...$`, with KaTeX `renderToString()` called directly in renderers for single-pass rendering.

---

## Problem Frame

zmdr uses marked.js for markdown-to-HTML conversion. LaTeX formulas delimited by `$$` and `$` are not recognized by marked.js and display as raw source code. Users writing math-heavy documents (linear algebra, calculus, abstract algebra) see unreadable TeX instead of typeset formulas.

---

## Requirements Trace

Origin: `docs/brainstorms/2026-06-01-math-formula-rendering-requirements.md`

| Plan Coverage | Origin IDs |
|---|---|
| Implementation units | R1, R2, R3, R4, R5, R6, R7 |
| Acceptance Examples | AE1, AE2, AE3, AE4, AE5, AE6 |

---

## Approach Selection

**Chosen: Scheme B — marked.js custom extensions** (see origin §Technical Approaches).

Rationale:
- marked.js custom extension API (`level: 'block'` / `'inline'`, `start()` + `tokenizer()` + `renderer()`) is well-documented and stable
- KaTeX `renderToString()` is synchronous — can be called directly in renderers for single-pass rendering, no post-processing needed
- `emStrongMask` hook protects underscores in math (e.g., `a_b`) from being parsed as italic markers
- Compared to Scheme A (preprocessing): no placeholder escaping concerns, no two-pass complexity, math is rendered at parse time

Scheme A is recorded in the origin document and can serve as fallback if the extension approach encounters marked.js version compatibility issues.

---

## Implementation Units

### U1. Add KaTeX CDN and CSS styles

**Goal:** Load KaTeX library and define math display styles.

**Requirements:** R4, R6

**Dependencies:** None

**Files:**
- `assets/index.html` — add CDN links and CSS

**Approach:**
- Add KaTeX CSS `<link>` before `</head>`: `katex@0.17.0/dist/katex.min.css`
- Add KaTeX JS `<script>` before existing scripts: `katex@0.17.0/dist/katex.min.js`
- Add `.math-block` CSS: centered, `overflow-x: auto`, margin matching `.mermaid-diagram`
- Add `.math-inline` CSS: `display: inline` (KaTeX handles this natively via `.katex` span)
- Add `.math-error` CSS: follow `.mermaid-error` pattern — red-tinted background with dark mode variant
- Add `@media (prefers-color-scheme: dark)` overrides for `.math-block .katex { color: #e6edf3 }` and `.math-error` dark variant

**Patterns to follow:** `.mermaid-diagram` and `.mermaid-error` CSS in existing stylesheet (assets/index.html:129-144)

**Test scenarios:**
- Formula renders in light mode with dark text on light background
- Formula renders in dark mode with light text on dark background
- `.math-error` styling matches `.mermaid-error` in both themes

**Verification:** KaTeX CSS and JS load without 404; `.math-block` and `.math-error` styles appear in browser devtools.

---

### U2. Add block-level math extension for `$$...$$`

**Goal:** marked.js recognizes `$$...$$` blocks and renders them as KaTeX display-mode formulas.

**Requirements:** R1, R5

**Dependencies:** U1 (KaTeX must be loaded before marked.parse())

**Files:**
- `assets/index.html` — add block extension and register via `marked.use()`

**Approach:**
- Register a custom extension `{ name: 'mathBlock', level: 'block', start, tokenizer, renderer }`
- `start(src)`: `src.match(/\$\$/)?.index` — hint to marked.js where to check
- `tokenizer(src)`: match regex `/^\$\$\s*\n?([\s\S]*?)\n?\s*\$\$/` anchored to `^`. Return token `{ type: 'mathBlock', raw: match[0], text: match[1].trim() }`. Return `false` if no match.
- `renderer(token)`: call `katex.renderToString(token.text, { displayMode: true, throwOnError: false })`. Wrap in `<div class="math-block">...</div>`. On exception, return `<div class="math-error">Formula error: ...</div>`.
- Extension registration is deferred to U3 — both block and inline extensions are registered in a single `marked.use()` call

**Patterns to follow:** Description list extension example in marked.js docs; existing `renderMermaid()` error handling pattern

**Test scenarios:**
- `$$\begin{bmatrix} a & b \\ c & d \end{bmatrix}$$` → centered matrix (Covers AE1)
- `$$a^n=\left\{ \begin{array}{c} e & n=0\\ ... \end{array} \right.$$` → multi-line piecewise function (Covers AE3)
- `$$\invalid{syntax$$` → error message in `.math-error`, no crash (Covers AE5)
- Single-line `$$E=mc^2$$` → rendered formula
- Empty `$$$$` → produces `<div class="math-block"></div>` without calling KaTeX (skip render when token text is empty), preserving block-level spacing via the CSS margin without injecting content

**Verification:** `marked.parse()` output for test markdown contains `.math-block > .katex` HTML structure. Error case produces `.math-error` element.

---

### U3. Add inline-level math extension for `$...$`

**Goal:** marked.js recognizes `$...$` inline formulas and renders them as KaTeX inline-mode formulas, while avoiding false positives on currency (`$100`).

**Requirements:** R2, R3, R7

**Dependencies:** U2 (extension registration pattern established; both extensions registered together)

**Files:**
- `assets/index.html` — add inline extension and `emStrongMask` hook

**Approach:**
- Register custom extension `{ name: 'mathInline', level: 'inline', start, tokenizer, renderer }`
- `start(src)`: `src.indexOf('$')` — find first `$`
- `tokenizer(src)`: match regex `/^\$(?!\d|\s)([^$\n]+?)\$/` anchored to `^`. Negative lookahead `(?!\d|\s)` implements R3 — `$` followed by digit or whitespace is not a formula start. Escaped `\$` (backslash before `$`) is not explicitly excluded by this regex; if the JS engine supports lookbehind, add `(?<!\\)` before `\$` to handle the `\$` escape case, otherwise defer to follow-up work. Return `{ type: 'mathInline', raw: match[0], text: match[1].trim() }`. Return `false` if no match (falls through to built-in tokenizers).
- `renderer(token)`: `katex.renderToString(token.text, { displayMode: false, throwOnError: false })`. Wrap in `<span class="math-inline">...</span>`.
- Add `emStrongMask` hook to protect math content from italic/bold parsing:

  ```js
  hooks: {
    emStrongMask(src) {
      return src.replace(/\$(?!\d|\s)([^$\n]+?)\$/g, (match) =>
        '[' + 'a'.repeat(match.length - 2) + ']');
    }
  }
  ```

  This ensures underscores like `a_b` inside `$...$` are not misinterpreted as italic markers before the custom extension can consume them.
- Register both extensions and hooks in a single `marked.use()` call

**Patterns to follow:** `emStrongMask` example in marked.js USING_PRO docs; `codespan` override example for `$...$` in same docs

**Test scenarios:**
- `$\left<\mathbb{Z}_6,+_{\bmod}\right>$ 的生成元是 $\{1,5\}$` → two inline formulas rendered alongside Chinese text (Covers AE2)
- `价格 $100 和 $50` → `$100` and `$50` remain as plain text, not formulas (Covers AE4)
- `$E=mc^2$` → simple inline formula
- `$a_b$` — underscores in math not parsed as italic (subscript renders correctly)
- Combined: document with `$$` block + `$` inline + Mermaid diagram + fenced code block + TOC → all five features work (Covers AE6)

**Verification:** `marked.parse()` output for test markdown contains `.math-inline > .katex` inline. Currency `$100` appears as plain text. Underscores in `$a_b$` render as subscript, not italic.

---

## Scope Boundaries

- No `\(...\)` / `\[...\]` delimiter support
- No Zig backend changes — pure frontend change to `assets/index.html`
- No auto-render extension (manual tokenizer approach used instead)

### Deferred to Follow-Up Work

- KaTeX auto-render extension as alternative detection strategy — if regex-based tokenizing proves fragile in practice

---

## Key Technical Decisions

- **Scheme B over Scheme A**: Single-pass rendering via marked.js extensions avoids placeholder escaping issues and is more idiomatic with the library architecture. The `emStrongMask` hook is specifically designed for this use case.
- **Synchronous `katex.renderToString()` in renderer**: KaTeX is synchronous by design. For typical markdown documents (<50 formulas), this is negligible. Extremely formula-heavy documents (>100) could see frame delay, but this is an edge case for a desktop viewer.
- **`emStrongMask` as safety net**: Even though the custom inline extension runs before `emStrong` and should consume `$...$` content first, the mask prevents edge cases where unmatched `$` or partial content leaks through to the italic parser.
- **`$` followed by digit/whitespace excluded**: Simple heuristic covers currency and spacing without needing a full LaTeX-aware parser for delimiter detection.

---

## Dependencies / Assumptions

- KaTeX 0.17.0 available on jsDelivr CDN
- marked.js version loaded via `marked@latest` CDN supports the custom extension API (v4+)
- User documents use `$` for math, not as a literal dollar sign adjacent to non-digit text
- `\begin{}...\end{}` environments (matrix, array, cases, etc.) are supported by KaTeX

---

## Deferred to Implementation

- Exact CSS values for `.math-block` margin/spacing — tune visually
- Whether KaTeX CSS needs additional font-related overrides for WebKit WebView
