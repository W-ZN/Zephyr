# Fixed benchmark corpus (design §3.4): Chinese and English prose, unique formulas, tables, code,
# a 20 MB single paragraph, and very long lines. Deterministic (seeded), written to the folder given
# on the command line (normally build.noindex/output/corpus, never committed).
import random
import sys
import struct
import zlib
from pathlib import Path

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
rng = random.Random(20261001)

zh = "文件本身就是文档阅读器只修改你授权的字节公式表格结构一目了然范围扩大到所在文件夹搜索引用然后回到阅读轻量安静随用随走中文输入法组字键盘辅助功能"
en = "zephyr opens markdown files in place renders them for reading and writes back only the bytes you change light quiet native byte exact scope search".split()


def zh_words(n):
    return "".join(rng.choice(zh) for _ in range(n))


def en_words(n):
    return " ".join(rng.choice(en) for _ in range(n))


def sentence():
    return f"{zh_words(rng.randint(8, 20))} {en_words(rng.randint(2, 6))} {zh_words(rng.randint(6, 14))}，`code{rng.randint(0, 999)}` 和 **{zh_words(3)}**。"


def formula(i):
    a, b, c = rng.randint(1, 9), rng.randint(2, 12), rng.randint(1, 30)
    kinds = [
        rf"\int_0^{{{b}}} x^{{{a}}} e^{{-{c}x}}\,dx",
        rf"\sum_{{k=1}}^{{{b * 10}}} \frac{{{a}}}{{k^{{{c % 4 + 2}}}}}",
        rf"\begin{{pmatrix}} {a} & {b} \\ {c} & {i} \end{{pmatrix}}",
        rf"\sqrt{{{a}x^2 + {b}x + {c}}} = {i}",
        rf"\lim_{{n\to\infty}} \left(1 + \frac{{{a}}}{{n}}\right)^{{{b}n}} = e^{{{a * b}}}",
    ]
    return kinds[i % len(kinds)] + rf" + {i}"


def section(i, formulas=0, start=0):
    lines = [f"## 第 {i} 节 Section {i}", ""]
    for _ in range(rng.randint(2, 4)):
        lines.append(" ".join(sentence() for _ in range(rng.randint(2, 5))))
        lines.append("")
    lines += [f"- {sentence()}", f"- {sentence()}", f"  - {sentence()}", ""]
    if i % 5 == 0:
        lines += ["| 指标 | 数值 | 说明 |", "|---|---:|---|"] + [f"| {zh_words(4)} | {rng.randint(1, 999)} | {en_words(4)} |" for _ in range(4)] + [""]
    if i % 7 == 0:
        lines += ["```swift", f"let value{i} = compute({rng.randint(0, 99)})", "print(value)", "```", ""]
    for j in range(formulas):
        n = start + j
        if n % 3 == 0:
            lines += ["$$", formula(n), "$$", ""]
        else:
            lines += [f"行内公式 ${formula(n)}$ {zh_words(10)}。", ""]
    return "\n".join(lines) + "\n"


# 1 MB of mixed prose with tables and code.
text = "# 1 MB 文档\n\n"
i = 0
while len(text.encode()) < 1_000_000:
    i += 1
    text += section(i)
(out / "prose-1mb.md").write_text(text)

# 900 and 3000 unique formulas spread over sections.
for total in (900, 3000):
    text = f"# {total} 个公式\n\n"
    n = 0
    i = 0
    while n < total:
        i += 1
        k = min(6, total - n)
        text += section(i, formulas=k, start=n)
        n += k
    (out / f"math-{total}.md").write_text(text)

# One 20 MB paragraph: no line breaks at all.
parts = []
size = 0
while size < 20_000_000:
    s = sentence() + " "
    parts.append(s)
    size += len(s.encode())
(out / "paragraph-20mb.md").write_text("# 20 MB 单段\n\n" + "".join(parts) + "\n")

# Very long lines: 40 lines of about 100 KB each.
lines = ["# 超长行", ""]
for _ in range(40):
    line = ""
    while len(line.encode()) < 100_000:
        line += sentence() + " "
    lines += [line, ""]
(out / "long-lines.md").write_text("\n".join(lines))

# 20 MB of prose: the automatic large-file route uses the same canvas in source mode.
parts = ["# 20 MB 文档\n\n"]
size = 0
i = 0
while size < 20_000_000:
    i += 1
    s = section(i)
    parts.append(s)
    size += len(s.encode())
(out / "prose-20mb.md").write_text("".join(parts))

# Many distinct local images exercise pixel-cache eviction without adding a dependency.
images = out / "images"
images.mkdir(exist_ok=True)
def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
links = ["# Local image cache", ""]
for i in range(40):
    pixel = bytes([(i * 47) % 256, (i * 83) % 256, (i * 19) % 256])
    scanlines = (b"\0" + pixel * 2048) * 2048
    png = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 2048, 2048, 8, 2, 0, 0, 0)) + png_chunk(b"IDAT", zlib.compress(scanlines)) + png_chunk(b"IEND", b"")
    (images / f"{i:02d}.png").write_bytes(png)
    links.extend([f"![Image {i}](images/{i:02d}.png)", ""])
(out / "images-40.md").write_text("\n".join(links))

for p in sorted(out.glob("*.md")):
    print(f"{p.name}\t{p.stat().st_size / 1e6:.1f} MB")
