#!/usr/bin/env python3
"""Run the isolated Sparkle CLI update contract for Zephyr build 2 -> build 3.

The script never uses /Applications or an existing Zephyr installation. It creates a
new run below build.noindex/output/update-check, launches the supplied candidate only
in snapshot mode with an isolated CFFIXED_USER_HOME, and leaves every log and partial
result behind for review.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import http.server
import json
import os
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OUTPUT_PARENT = ROOT / "build.noindex" / "output"
ALLOWED_SPARKLE_DEFAULTS = {
    "SUHasLaunchedBefore",
    "SULastCheckTime",
    "SUInitialFailedFeedSigningValidationDate",
}
PERSISTENT_PATHS = [
    "Library/Preferences/dev.zephyr.Zephyr.plist",
    "Library/Application Support/Zephyr/appearance.json",
    "Library/Application Support/Zephyr/Themes",
    "Library/Application Support/Zephyr/credentials.json",
    "Library/Application Support/Zephyr/credentials.key",
    "Library/Application Support/Zephyr/Space",
    "Library/Application Support/Zephyr/Activity.json",
    "Library/Application Support/Zephyr/recovery",
]
SNAPSHOT_TIMEOUT_SECONDS = 60
UPDATE_TIMEOUT_SECONDS = 180


def fail(message: str) -> None:
    raise RuntimeError(message)


def require_file(path: Path, label: str, executable: bool = False) -> None:
    if not path.is_file():
        fail(f"{label} is not a file: {path}")
    if executable and not os.access(path, os.X_OK):
        fail(f"{label} is not executable: {path}")


def require_directory(path: Path, label: str) -> None:
    if not path.is_dir():
        fail(f"{label} is not a directory: {path}")


def must_be_under(path: Path, parent: Path, label: str) -> None:
    try:
        path.resolve().relative_to(parent.resolve())
    except ValueError:
        fail(f"{label} must be below {parent}: {path}")


def run_command(
    logs: Path,
    name: str,
    command: list[str],
    *,
    env: dict[str, str] | None = None,
    timeout: int = UPDATE_TIMEOUT_SECONDS,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    (logs / f"{name}.command.txt").write_text(shlex.join(command) + "\n", encoding="utf-8")
    started = time.monotonic()
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        output = (error.stdout or "") + (error.stderr or "")
        (logs / f"{name}.log").write_text(output, encoding="utf-8")
        (logs / f"{name}.json").write_text(
            json.dumps({"command": command, "timed_out_after_seconds": timeout}, indent=2) + "\n",
            encoding="utf-8",
        )
        fail(f"{name} exceeded its {timeout}-second stop condition; see {logs / f'{name}.log'}")

    (logs / f"{name}.log").write_text(completed.stdout, encoding="utf-8")
    (logs / f"{name}.json").write_text(
        json.dumps(
            {
                "command": command,
                "exit_code": completed.returncode,
                "elapsed_seconds": round(time.monotonic() - started, 3),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return completed


def expect_success(result: subprocess.CompletedProcess[str], label: str, logs: Path) -> None:
    if result.returncode != 0:
        fail(f"{label} exited {result.returncode}; see {logs / f'{label}.log'}")


def expect_failure(result: subprocess.CompletedProcess[str], label: str, logs: Path) -> None:
    if result.returncode == 0:
        fail(f"{label} unexpectedly succeeded; see {logs / f'{label}.log'}")


def plist_value(bundle: Path, key: str) -> str:
    result = subprocess.run(
        ["/usr/libexec/PlistBuddy", "-c", f"Print :{key}", str(bundle / "Contents" / "Info.plist")],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        fail(f"Could not read {key} from {bundle}: {result.stderr.strip()}")
    return result.stdout.strip()


def bundle_values(bundle: Path) -> dict[str, str]:
    return {
        "identifier": plist_value(bundle, "CFBundleIdentifier"),
        "short_version": plist_value(bundle, "CFBundleShortVersionString"),
        "build": plist_value(bundle, "CFBundleVersion"),
        "public_key": plist_value(bundle, "SUPublicEDKey"),
    }


def verify_bundle(
    logs: Path,
    label: str,
    bundle: Path,
    expected_identifier: str,
    expected_short_version: str,
    expected_build: str,
    expected_public_key: str,
) -> None:
    require_directory(bundle, f"{label} bundle")
    values = bundle_values(bundle)
    expected = {
        "identifier": expected_identifier,
        "short_version": expected_short_version,
        "build": expected_build,
        "public_key": expected_public_key,
    }
    if values != expected:
        fail(f"{label} metadata mismatch: expected {expected | {'public_key': '<redacted>'}}, got {values | {'public_key': '<redacted>'}}")

    sparkle = bundle / "Contents/Frameworks/Sparkle.framework/Versions/B"
    for relative in ["Sparkle", "Autoupdate", "Updater.app", "XPCServices/Installer.xpc", "XPCServices/Downloader.xpc"]:
        if not (sparkle / relative).exists():
            fail(f"{label} is missing Sparkle component: {sparkle / relative}")

    result = run_command(logs, f"{label}-codesign", ["codesign", "--verify", "--deep", "--strict", str(bundle)])
    expect_success(result, f"{label}-codesign", logs)


def make_fixture(home: Path) -> None:
    prefs = home / "Library/Preferences/dev.zephyr.Zephyr.plist"
    support = home / "Library/Application Support/Zephyr"
    prefs.parent.mkdir(parents=True, exist_ok=True)
    support.mkdir(parents=True, exist_ok=True)
    with prefs.open("wb") as handle:
        plistlib.dump({"ZephyrFixture": "preserve app-owned preferences", "frontMatterCollapsed": True}, handle, fmt=plistlib.FMT_XML)

    (support / "appearance.json").write_text(
        json.dumps({"active": "paper", "themesFolder": None, "adjustments": {}}, indent=2) + "\n", encoding="utf-8"
    )
    themes = support / "Themes"
    themes.mkdir()
    (themes / "E2E Theme.json").write_text(
        json.dumps({"name": "E2E Theme", "tokens": {"accent": "#164E63"}}, indent=2) + "\n", encoding="utf-8"
    )
    (support / "credentials.json").write_text('{"fixture-endpoint":"AQID"}\n', encoding="utf-8")
    (support / "credentials.key").write_bytes(bytes(range(32)))
    space = support / "Space/Today"
    space.mkdir(parents=True)
    (space.parent / "Goals.md").write_text("# Goals\n\n- [ ] Preserve update data\n", encoding="utf-8")
    (space / "2026-10-12.md").write_text("# Today\n\n- [x] Update fixture\n", encoding="utf-8")
    (support / "Activity.json").write_text(
        json.dumps(
            {
                "version": 1,
                "days": [{"date": "2026-10-12", "opened": ["fixture.md"], "added": [], "removed": [], "modified": [], "saturated": False}],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    recovery = support / "recovery"
    recovery.mkdir()
    (recovery / "fixture.json").write_text('{"state":"applied","checkpoint":"fixture"}\n', encoding="utf-8")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest(home: Path) -> dict[str, dict[str, str | int]]:
    entries: dict[str, dict[str, str | int]] = {}
    for relative in PERSISTENT_PATHS:
        root = home / relative
        if not root.exists() and not root.is_symlink():
            entries[relative] = {"type": "absent"}
            continue
        paths = [root] if not root.is_dir() else [root, *sorted(root.rglob("*"))]
        for path in paths:
            rel = path.relative_to(home).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                entries[rel] = {"type": "symlink", "target": os.readlink(path)}
            elif path.is_dir():
                entries[rel] = {"type": "directory"}
            elif path.is_file():
                entries[rel] = {"type": "file", "bytes": path.stat().st_size, "sha256": sha256(path)}
            else:
                entries[rel] = {"type": "other"}
    return entries


def read_plist(path: Path) -> dict[object, object]:
    with path.open("rb") as handle:
        payload = plistlib.load(handle)
    if not isinstance(payload, dict):
        fail(f"Expected dictionary preferences plist: {path}")
    return payload


def verify_persistent_data(case: Path) -> None:
    home = case / "home"
    before = json.loads((case / "state-before.json").read_text(encoding="utf-8"))
    after = manifest(home)
    (case / "state-after.json").write_text(json.dumps(after, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    preferences_relative = "Library/Preferences/dev.zephyr.Zephyr.plist"
    before_other = {key: value for key, value in before.items() if key != preferences_relative}
    after_other = {key: value for key, value in after.items() if key != preferences_relative}
    if before_other != after_other:
        fail(f"Persistent Zephyr data changed outside Sparkle bookkeeping in {case}; compare state-before.json and state-after.json")

    before_plist = read_plist(case / "preferences-before.plist")
    after_path = home / preferences_relative
    shutil.copy2(after_path, case / "preferences-after.plist")
    after_plist = read_plist(after_path)
    before_app_owned = {key: value for key, value in before_plist.items() if key not in ALLOWED_SPARKLE_DEFAULTS}
    after_app_owned = {key: value for key, value in after_plist.items() if key not in ALLOWED_SPARKLE_DEFAULTS}
    if before_app_owned != after_app_owned:
        fail(f"App-owned UserDefaults changed in {case}; compare preferences-before.plist and preferences-after.plist")

    sparkle_changes = {
        key: {"before": repr(before_plist.get(key)), "after": repr(after_plist.get(key))}
        for key in sorted(ALLOWED_SPARKLE_DEFAULTS)
        if before_plist.get(key) != after_plist.get(key)
    }
    (case / "preferences-sparkle-bookkeeping.json").write_text(
        json.dumps({"allowed_keys": sorted(ALLOWED_SPARKLE_DEFAULTS), "changed": sparkle_changes}, indent=2) + "\n",
        encoding="utf-8",
    )


def assert_not_running(bundle: Path, record: Path) -> None:
    executable = str(bundle / "Contents/MacOS/Zephyr")
    process_list = subprocess.run(["ps", "-axo", "pid=,command="], text=True, stdout=subprocess.PIPE, check=True).stdout
    matches = []
    for line in process_list.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) == 2 and executable in fields[1] and int(fields[0]) != os.getpid():
            matches.append(line)
    record.write_text("\n".join(matches) + ("\n" if matches else ""), encoding="utf-8")
    if matches:
        fail(f"Synthetic target is running and must not be updated: {executable}")


def start_server(root: Path, server_log: Path) -> tuple[http.server.ThreadingHTTPServer, threading.Thread, str]:
    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args: object, **kwargs: object) -> None:
            super().__init__(*args, directory=str(root), **kwargs)

        def log_message(self, format: str, *args: object) -> None:
            with server_log.open("a", encoding="utf-8") as handle:
                handle.write("%s %s\n" % (self.log_date_time_string(), format % args))

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, name="sparkle-e2e-http", daemon=True)
    thread.start()
    return server, thread, f"http://127.0.0.1:{server.server_port}/"


def tamper_feed(feed: Path) -> None:
    payload = bytearray(feed.read_bytes())
    match = re.search(rb"<title>([^<]+)</title>", payload)
    if match is None:
        fail(f"Could not find a textual title to tamper in {feed}")
    position = next((index for index in range(match.start(1), match.end(1)) if chr(payload[index]).isalpha()), None)
    if position is None:
        fail(f"Could not find an ASCII title character to tamper in {feed}")
    payload[position] = ord("X") if payload[position] != ord("X") else ord("Y")
    feed.write_bytes(payload)
    ET.parse(feed)


def tamper_archive(archive: Path) -> None:
    payload = bytearray(archive.read_bytes())
    if not payload:
        fail(f"Cannot tamper empty archive: {archive}")
    payload[-1] ^= 1
    archive.write_bytes(payload)


def make_old_copy(
    logs: Path,
    case: Path,
    candidate: Path,
    old_version: str,
    old_build: str,
    expected_identifier: str,
    expected_public_key: str,
) -> Path:
    old_bundle = case / "Zephyr.app"
    result = run_command(logs, f"{case.name}-copy", ["ditto", str(candidate), str(old_bundle)])
    expect_success(result, f"{case.name}-copy", logs)
    plist = old_bundle / "Contents/Info.plist"
    for key, value in [("CFBundleShortVersionString", old_version), ("CFBundleVersion", old_build)]:
        result = run_command(logs, f"{case.name}-set-{key}", ["/usr/libexec/PlistBuddy", "-c", f"Set :{key} {value}", str(plist)])
        expect_success(result, f"{case.name}-set-{key}", logs)

    signing_env = dict(os.environ, ADHOC="1", ROOT=str(ROOT))
    result = run_command(logs, f"{case.name}-adhoc-sign", [str(ROOT / "apps/macos/scripts/sign.sh"), str(old_bundle)], env=signing_env)
    expect_success(result, f"{case.name}-adhoc-sign", logs)
    verify_bundle(logs, f"{case.name}-old", old_bundle, expected_identifier, old_version, old_build, expected_public_key)
    assert_not_running(old_bundle, case / "target-processes-before.txt")

    home = case / "home"
    make_fixture(home)
    state_before = manifest(home)
    (case / "state-before.json").write_text(json.dumps(state_before, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    shutil.copy2(home / "Library/Preferences/dev.zephyr.Zephyr.plist", case / "preferences-before.plist")
    return old_bundle


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-app", required=True, type=Path)
    parser.add_argument("--candidate-dmg", required=True, type=Path)
    parser.add_argument("--sparkle-cli", required=True, type=Path)
    parser.add_argument("--generate-keys", required=True, type=Path)
    parser.add_argument("--generate-appcast", required=True, type=Path)
    parser.add_argument("--account", required=True)
    parser.add_argument("--output-root", type=Path, default=OUTPUT_PARENT / "update-check")
    parser.add_argument("--expected-bundle-id", default="dev.zephyr.Zephyr")
    parser.add_argument("--old-version", default="0.1.1")
    parser.add_argument("--old-build", default="2")
    parser.add_argument("--new-version", default="0.1.2")
    parser.add_argument("--new-build", default="3")
    args = parser.parse_args()

    candidate = args.candidate_app.resolve()
    candidate_dmg = args.candidate_dmg.resolve()
    output_root = args.output_root.resolve()
    must_be_under(output_root, OUTPUT_PARENT, "output root")
    if candidate.is_relative_to(Path("/Applications")):
        fail("candidate app must be a checkout artifact, not /Applications")
    require_directory(candidate, "candidate app")
    require_file(candidate_dmg, "candidate DMG")
    for path, label in [
        (args.sparkle_cli.resolve(), "sparkle CLI"),
        (args.generate_keys.resolve(), "generate_keys"),
        (args.generate_appcast.resolve(), "generate_appcast"),
    ]:
        require_file(path, label, executable=True)

    output_root.mkdir(parents=True, exist_ok=True)
    run = output_root / f"sparkle-cli-e2e-{dt.datetime.now().strftime('%Y%m%dT%H%M%S')}-{os.getpid()}"
    run.mkdir()
    logs = run / "logs"
    logs.mkdir()
    result_path = run / "result.json"
    result: dict[str, object] = {
        "question": "Does the packaged 0.1.2/build 3 Zephyr app accept a signed local Sparkle update from synthetic 0.1.1/build 2 and reject tampered feed/archive inputs?",
        "primary_metric": "The positive target changes CFBundleVersion 2 to 3 at the same path; each negative target remains build 2.",
        "acceptance": "Positive feed probe and install return zero, installed bundle passes codesign/metadata checks, app-owned persistent data is unchanged; tampered feed probe and tampered archive install return nonzero without replacing their fresh targets.",
        "budget": {"snapshot_timeout_seconds": SNAPSHOT_TIMEOUT_SECONDS, "each_cli_timeout_seconds": UPDATE_TIMEOUT_SECONDS, "cases": ["positive", "tampered-feed", "tampered-archive"]},
        "stop_condition": "Any command timeout, signature failure, metadata mismatch, persistent app-data mutation, or unexpected negative success ends the run and retains artifacts.",
        "status": "RUNNING",
    }
    result_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    server: http.server.ThreadingHTTPServer | None = None

    try:
        tool_home = run / "tool-home"
        tool_home.mkdir()
        tool_env = dict(os.environ, CFFIXED_USER_HOME=str(tool_home))
        public_result = run_command(logs, "public-key", [str(args.generate_keys), "--account", args.account, "-p"], env=tool_env, timeout=30)
        expect_success(public_result, "public-key", logs)
        account_public_key = next((line.strip() for line in reversed(public_result.stdout.splitlines()) if line.strip()), "")
        if not account_public_key:
            fail("generate_keys did not return a public key")

        candidate_values = bundle_values(candidate)
        if candidate_values["public_key"] == "REPLACE_WITH_SPARKLE_ED25519_PUBLIC_KEY":
            fail("candidate still has the public-key placeholder")
        if candidate_values["public_key"] != account_public_key:
            fail("candidate SUPublicEDKey does not match the selected Keychain account")
        verify_bundle(
            logs,
            "candidate",
            candidate,
            args.expected_bundle_id,
            args.new_version,
            args.new_build,
            account_public_key,
        )

        runtime = run / "candidate-runtime"
        runtime_home = runtime / "home"
        runtime.mkdir()
        runtime_fixture = runtime / "fixture.md"
        runtime_fixture.write_text("# Sparkle runtime probe\n\nThe embedded framework must load.\n", encoding="utf-8")
        snapshot = runtime / "snapshot.png"
        runtime_env = dict(os.environ, CFFIXED_USER_HOME=str(runtime_home), HOME=str(runtime_home))
        snapshot_result = run_command(
            logs,
            "candidate-snapshot",
            [
                str(candidate / "Contents/MacOS/Zephyr"),
                "-ZephyrOpen",
                str(runtime_fixture),
                "-ZephyrSnapshot",
                str(snapshot),
                "-ZephyrWait",
                "1.2",
            ],
            env=runtime_env,
            timeout=SNAPSHOT_TIMEOUT_SECONDS,
        )
        expect_success(snapshot_result, "candidate-snapshot", logs)
        if not snapshot.is_file() or snapshot.stat().st_size < 8 or snapshot.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            fail("candidate snapshot did not produce a readable PNG")

        server_root = run / "server"
        server_root.mkdir()
        archive = server_root / candidate_dmg.name
        shutil.copy2(candidate_dmg, archive)
        server, server_thread, prefix = start_server(server_root, logs / "http-server.log")
        feed = server_root / "appcast.xml"
        generate_result = run_command(
            logs,
            "generate-appcast",
            [
                str(args.generate_appcast),
                "--account",
                args.account,
                "--download-url-prefix",
                prefix,
                "--maximum-deltas",
                "0",
                "-o",
                str(feed),
                str(server_root),
            ],
            env=tool_env,
        )
        expect_success(generate_result, "generate-appcast", logs)
        require_file(feed, "generated appcast")

        verify_command = ["swift", str(ROOT / "apps/macos/scripts/verify-appcast.swift"), str(feed), str(archive), str(candidate / "Contents/Info.plist")]
        feed_verify = run_command(logs, "verify-clean-release", verify_command)
        expect_success(feed_verify, "verify-clean-release", logs)
        result["static_verification"] = "passed using embedded public key"

        clean = run / "clean"
        clean.mkdir()
        clean_feed = clean / feed.name
        clean_archive = clean / archive.name
        shutil.copy2(feed, clean_feed)
        shutil.copy2(archive, clean_archive)

        def restore_clean_server() -> None:
            shutil.copy2(clean_feed, feed)
            shutil.copy2(clean_archive, archive)

        def cli_env(case: Path) -> dict[str, str]:
            return dict(os.environ, CFFIXED_USER_HOME=str(case / "home"), HOME=str(case / "home"))

        feed_url = prefix + feed.name
        positive = run / "positive"
        positive.mkdir()
        old_positive = make_old_copy(logs, positive, candidate, args.old_version, args.old_build, args.expected_bundle_id, account_public_key)
        probe = run_command(
            logs,
            "positive-probe",
            [str(args.sparkle_cli), str(old_positive), "--probe", "--feed-url", feed_url, "--user-agent-name", "Zephyr local E2E", "--verbose"],
            env=cli_env(positive),
        )
        expect_success(probe, "positive-probe", logs)
        install = run_command(
            logs,
            "positive-install",
            [str(args.sparkle_cli), str(old_positive), "--check-immediately", "--feed-url", feed_url, "--user-agent-name", "Zephyr local E2E", "--verbose"],
            env=cli_env(positive),
        )
        expect_success(install, "positive-install", logs)
        verify_bundle(logs, "positive-installed", old_positive, args.expected_bundle_id, args.new_version, args.new_build, account_public_key)
        verify_persistent_data(positive)
        result["positive"] = "passed"

        restore_clean_server()
        tamper_feed(feed)
        tampered_feed_verify = run_command(logs, "verify-tampered-feed", verify_command)
        expect_failure(tampered_feed_verify, "verify-tampered-feed", logs)
        bad_feed = run / "tampered-feed"
        bad_feed.mkdir()
        old_bad_feed = make_old_copy(logs, bad_feed, candidate, args.old_version, args.old_build, args.expected_bundle_id, account_public_key)
        bad_feed_probe = run_command(
            logs,
            "tampered-feed-probe",
            [str(args.sparkle_cli), str(old_bad_feed), "--probe", "--feed-url", feed_url, "--user-agent-name", "Zephyr local E2E", "--verbose"],
            env=cli_env(bad_feed),
        )
        expect_failure(bad_feed_probe, "tampered-feed-probe", logs)
        verify_bundle(logs, "tampered-feed-old", old_bad_feed, args.expected_bundle_id, args.old_version, args.old_build, account_public_key)
        verify_persistent_data(bad_feed)
        result["tampered_feed"] = "rejected"

        restore_clean_server()
        tamper_archive(archive)
        tampered_archive_verify = run_command(logs, "verify-tampered-archive", verify_command)
        expect_failure(tampered_archive_verify, "verify-tampered-archive", logs)
        bad_archive = run / "tampered-archive"
        bad_archive.mkdir()
        old_bad_archive = make_old_copy(logs, bad_archive, candidate, args.old_version, args.old_build, args.expected_bundle_id, account_public_key)
        bad_archive_install = run_command(
            logs,
            "tampered-archive-install",
            [str(args.sparkle_cli), str(old_bad_archive), "--check-immediately", "--feed-url", feed_url, "--user-agent-name", "Zephyr local E2E", "--verbose"],
            env=cli_env(bad_archive),
        )
        expect_failure(bad_archive_install, "tampered-archive-install", logs)
        verify_bundle(logs, "tampered-archive-old", old_bad_archive, args.expected_bundle_id, args.old_version, args.old_build, account_public_key)
        verify_persistent_data(bad_archive)
        result["tampered_archive"] = "rejected"
        result["status"] = "COMPLETED"
        result_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"COMPLETED: {run}")
        return 0
    except Exception as error:
        result["status"] = "FAILED"
        result["error"] = str(error)
        result_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"FAILED: {error}\nArtifacts: {run}", file=sys.stderr)
        return 1
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
