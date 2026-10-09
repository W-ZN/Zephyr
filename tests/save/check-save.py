"""Byte-exact save check through the real app (design §2 principle 1, §5): each case opens a file in
Zephyr, optionally types at a UTF-16 offset, saves through NSDocument and exits. The file must hold
exactly the expected bytes, keep its permissions and extended attributes, and its folder must gain
no files (no `name~.md` backup either, even when the app exits right after saving).

Usage: check-save.py <Zephyr.app> <work dir> <sandbox home>
"""
import os, shutil, subprocess, sys

app, work, home = sys.argv[1:4]
binary = os.path.join(app, "Contents/MacOS/Zephyr")


def u16(text):
    return len(text.encode("utf-16-le")) // 2


# name, original bytes, (prefix before the caret, typed text) or None, expected bytes or None (= unchanged), save should fail
mixed = b"# Mixed\n\nline one  \r\nline two\rline three\n\ttab\nno final newline"
cases = [
    ("bom-crlf", b"\xef\xbb\xbf# \xe6\xa0\x87\xe9\xa2\x98\r\n\r\n\xe6\xad\xa3\xe6\x96\x87 English.\r\n- a\r\n- b\r\n", None, None, False),
    ("mixed", mixed, None, None, False),
    ("mixed-edit", mixed, ("# Mixed\n\nline one  \r\n", "X"), mixed.replace(b"line two", b"Xline two"), False),
    ("crlf-return", b"para one\r\n\r\npara two\r\n", ("para one", "\nnew"), b"para one\r\nnew\r\n\r\npara two\r\n", False),
    ("bom-edit", b"\xef\xbb\xbfa\r\nb\r\n", ("a\r\n", "Z"), b"\xef\xbb\xbfa\r\nZb\r\n", False),
    ("unicode", "é \U0001F469‍\U0001F4BB 中文　全角\n".encode(), None, None, False),
    ("unicode-edit", "é \U0001F469‍\U0001F4BB 中文\n".encode(), ("é \U0001F469‍\U0001F4BB ", "字"),
     "é \U0001F469‍\U0001F4BB 字中文\n".encode(), False),
    ("empty", b"", None, None, False),
    ("nul", b"a\x00b\n", None, None, False),
    ("invalid-utf8", b"ok\n\xff\xfe bad\n", None, None, True),
]

shutil.rmtree(work, ignore_errors=True)
failures = 0
for name, original, edit, expected, should_fail in cases:
    folder = os.path.join(work, name)
    os.makedirs(folder)
    path = os.path.join(folder, name + ".md")
    with open(path, "wb") as f:
        f.write(original)
    os.chmod(path, 0o640)
    subprocess.run(["xattr", "-w", "dev.zephyr.test", "keep", path], check=True)
    args = [binary, "-ZephyrOpen", path, "-ZephyrSave", "YES"]
    if edit:
        args += ["-ZephyrSelect", str(u16(edit[0])), "-ZephyrType", edit[1]]
    try:
        run = subprocess.run(args, env=dict(os.environ, CFFIXED_USER_HOME=home), capture_output=True, text=True, timeout=60)
        status = run.stdout.strip().splitlines()[-1] if run.stdout.strip() else f"exit {run.returncode}"
    except subprocess.TimeoutExpired:
        status = "timeout"
    with open(path, "rb") as f:
        actual = f.read()
    want = expected if expected is not None else original
    problems = []
    if actual != want:
        problems.append(f"bytes differ: {actual!r} != {want!r}")
    if should_fail != status.startswith("error"):
        problems.append(f"save status {status!r}")
    if os.stat(path).st_mode & 0o777 != 0o640:
        problems.append(f"mode {oct(os.stat(path).st_mode & 0o777)}")
    if subprocess.run(["xattr", "-p", "dev.zephyr.test", path], capture_output=True, text=True).stdout.strip() != "keep":
        problems.append("extended attribute lost")
    extra = sorted(set(os.listdir(folder)) - {name + ".md"})
    if extra:
        problems.append(f"new files {extra}")
    failures += bool(problems)
    print(f"{'FAIL' if problems else 'ok  '} {name:14} {status:40.40} {'; '.join(problems)}")
print(f"{len(cases) - failures}/{len(cases)} passed")
sys.exit(1 if failures else 0)
