---
title: Zephyr 渲染样本
tags: [fixture, snapshot]
---

# Zephyr 渲染样本

这是一段中英文混排的正文：Zephyr 直接打开已有的 Markdown 文件，按需渲染，只把你改动的字节写回原文件。行内代码 `NSLayoutManager`、**加粗**、*斜体*、~~删除线~~ 和[链接](https://example.com)都应该在光标离开后隐藏标记。

## 公式

行内公式 $E = mc^2$ 与正文基线对齐，块公式单独成行：

$$
\int_{-\infty}^{\infty} e^{-x^2}\,dx = \sqrt{\pi}
$$

## 列表与任务

- 单文件默认，不枚举目录
  - 扩大范围时只列文件名
- 搜索按需扫描，不建索引

1. 读懂
2. 判断与修改
3. 找上下文

- [x] 字节级往返
- [ ] Quick Look 实测

> 引用块：文件是唯一真源，卸载后不留痕迹。

## 代码与表格

```swift
let document = try SourceDecoder.decode(data)
print(document.lines.count)
```

| 场景 | 目标 |
|---|---:|
| 打开 1 MB 文档 | ≤ 50 MB |
| 每多开一个窗口 | ≤ 10 MB |

---

最后一段：English text with a footnote-like aside, 以及中文标点「引号」和——破折号。
