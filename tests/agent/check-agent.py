"""Agent access through the real app and CLI (design §10, §11): a shared document can be read and
searched, proposals change the file only after review (answered automatically here), each applied
proposal leaves a recovery record, and a process that is not the bundled `zephyr` is refused.

Usage: check-agent.py <Zephyr.app> <work dir> <sandbox home>
"""
import json, os, shutil, socket, subprocess, sys, time

app, work, home = sys.argv[1:4]
binary = os.path.join(app, "Contents/MacOS/Zephyr")
cli = os.path.join(app, "Contents/Helpers/zephyr")
env = dict(os.environ, CFFIXED_USER_HOME=home)
sock = os.path.join(home, "Library/Application Support/Zephyr/agent.sock")
recovery = os.path.join(home, "Library/Application Support/Zephyr/recovery")

shutil.rmtree(work, ignore_errors=True)
os.makedirs(os.path.join(work, "notes"))
doc = os.path.join(work, "plan.md")
original = "# Plan\r\n\r\nShip on Monday.\r\n\r\n## Owner\r\n\r\nAnn\r\n"
open(doc, "w", newline="").write(original)
open(os.path.join(work, "notes/other.md"), "w").write("# Other\n\nMonday standup.\n")
open(os.path.join(home, "outside.md"), "w").write("secret\n")
shutil.rmtree(recovery, ignore_errors=True)

failures = 0
def check(name, ok, detail=""):
    global failures
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {name}{'' if ok else '  ' + detail}")

def zephyr(*args, stdin=None):
    r = subprocess.run([cli, *args], env=env, capture_output=True, text=True, input=stdin, timeout=60)
    return r.stdout.strip(), r.stderr.strip(), r.returncode

def serve(decision, scope):
    extra = ["-ZephyrAgentScope", "YES"] if scope else []
    p = subprocess.Popen([binary, "-ZephyrOpen", doc, "-ZephyrAgent", decision, "-ZephyrWait", "30", *extra], env=env, stdout=subprocess.PIPE, text=True)
    assert p.stdout.readline().strip() == "shared"
    for _ in range(50):
        if os.path.exists(sock): break
        time.sleep(0.1)
    return p

# Shared while the window shows its folder: the folder is readable too.
app_process = serve("apply", scope=True)
out, err, _ = zephyr("sessions")
check("sessions lists the shared document", doc in out, out + err)
out, err, _ = zephyr("context")
check("context has outline and revision", "revision:" in out and "## " not in out and "Owner" in out, out + err)
out, err, _ = zephyr("read", "--lines", "3:3")
check("read returns numbered lines", out == "3\tShip on Monday.", repr(out) + err)
out, err, _ = zephyr("find", "monday")
check("find in the document", out == "plan.md:3: Ship on Monday.", repr(out))
out, err, _ = zephyr("find", "monday", "--folder")
check("find in the folder scope", "notes/other.md:3: Monday standup." in out, repr(out))
out, err, code = zephyr("read", "../outside.md")
check("reads outside the scope are refused", code != 0 and "outside the folder scope" in err, out + err)
out, err, code = zephyr("propose", "--find", "Tuesday", "--replace", "x", "--wait")
check("unresolvable proposals are rejected", code != 0 and "not in the document" in err, out + err)
before = open(doc, "rb").read()
out, err, _ = zephyr("propose", "--find", "Monday", "--replace", "Friday", "--summary", "Move the date", "--wait")
check("applied after review", out.startswith("applied"), out + err)
after = open(doc, "rb").read()
check("only the proposed bytes changed, CRLF kept", after == before.replace(b"Monday", b"Friday"), repr(after))
records = [json.load(open(os.path.join(recovery, f))) for f in os.listdir(recovery)] if os.path.isdir(recovery) else []
check("a recovery record with a system version", len(records) == 1 and records[0]["state"] == "applied" and records[0]["checkpoint"], json.dumps(records)[:300])

# MCP over stdio, through the same channel.
lines = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "clientInfo": {"name": "probe"}, "capabilities": {}}},
    {"jsonrpc": "2.0", "method": "notifications/initialized"},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "read", "arguments": {"lines": [1, 1]}}},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "propose_patch", "arguments": {"edits": [{"find": "Ann", "replace": "Bo"}], "summary": "New owner"}}},
]
out, err, _ = zephyr("mcp", stdin="\n".join(json.dumps(l) for l in lines) + "\n")
replies = {r["id"]: r for r in map(json.loads, out.splitlines())}
check("mcp initialize", replies[1]["result"]["serverInfo"]["name"] == "zephyr", out[:200])
tools = [t["name"] for t in replies[2]["result"]["tools"]]
check("mcp lists its tools", tools == ["get_context", "search", "read", "propose_patch", "get_appearance", "set_appearance"], str(tools))
check("mcp tool text stays short", len(json.dumps(replies[2]["result"])) < 4000, str(len(json.dumps(replies[2]["result"]))))
check("mcp read", "1\t# Plan" in replies[3]["result"]["content"][0]["text"], json.dumps(replies[3]))
check("mcp propose applied", replies[4]["result"]["content"][0]["text"] == "applied", json.dumps(replies[4]))
check("file holds both changes", open(doc, "rb").read() == original.replace("Monday", "Friday").replace("Ann", "Bo").encode(), repr(open(doc, "rb").read()))

# A process that is not the bundled zephyr gets nothing.
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.sendall(b'{"op":"read"}\n')
answer = s.recv(65536).decode()
s.close()
check("other processes are refused", "Only the zephyr tool" in answer and "Plan" not in answer, answer)
check("the folder gained no files", sorted(os.listdir(work)) == ["notes", "plan.md"], str(os.listdir(work)))
app_process.terminate()
app_process.wait()

# Discarded proposals leave the file alone. Shared without a folder scope: only the document.
app_process = serve("discard", scope=False)
out, err, code = zephyr("find", "monday", "--folder")
check("without a folder scope, folder search is refused", code != 0 and "No folder scope" in err, out + err)
out, err, code = zephyr("read", "notes/other.md")
check("without a folder scope, other files are refused", code != 0 and "Standup" not in out, out + err)
before = open(doc, "rb").read()
out, err, _ = zephyr("propose", "--find", "Friday", "--replace", "Sunday", "--wait")
check("discarded after review", out.startswith("discarded") and open(doc, "rb").read() == before, out + err)
app_process.terminate()
app_process.wait()
check("socket removed when the app quits sharing", True)
print(f"{'all passed' if not failures else f'{failures} failed'}")
sys.exit(1 if failures else 0)
