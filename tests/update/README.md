# Sparkle CLI update check

This is the smallest non-GUI update check for the 0.1.1/build 2 → 0.1.2/build 3 chain. It answers four concrete questions:

1. Can the packaged candidate load its embedded Sparkle framework in the supported `-ZephyrSnapshot` mode?
2. Does a fresh synthetic build-2 app see the signed local feed and install the signed build-3 DMG at the same path?
3. Does a changed signed appcast fail before replacement?
4. Does a changed archive fail before replacement?

The primary success signal is the synthetic target's `CFBundleVersion` changing from `2` to `3`. The script also verifies code signatures, bundle identity, public key, embedded Sparkle components, and app-owned persistent data. Each run uses a fresh directory under `build.noindex/output/update-check`, loopback HTTP only, and isolated `CFFIXED_USER_HOME` fixtures. It never reads or writes `/Applications`, an existing Zephyr installation, or real Zephyr Application Support data.

Build the vendor CLI once from the exact resolved 2.10.0 source checkout:

```bash
tests/update/build-sparkle-cli.sh
```

The output is `build.noindex/sparkle-cli-build/DerivedData/Build/Products/Release/sparkle.app/Contents/MacOS/sparkle`. The build deliberately uses its own DerivedData and does not disable code signing; Sparkle's CLI embeds installer helpers.

After a packaged candidate app has passed its isolated snapshot launch and the parent has prepared its signed DMG, run:

```bash
python3 tests/update/check-sparkle-cli-e2e.py \
  --candidate-app "$PWD/dist/Zephyr.app" \
  --candidate-dmg "$PWD/dist/Zephyr-0.1.2.dmg" \
  --sparkle-cli "$PWD/build.noindex/sparkle-cli-build/DerivedData/Build/Products/Release/sparkle.app/Contents/MacOS/sparkle" \
  --generate-keys "$PWD/build.noindex/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys" \
  --generate-appcast "$PWD/build.noindex/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --account dev.zephyr.Zephyr
```

The Keychain account is read by Sparkle's tools; the invocation accepts no private-key file or private-key value. Its `generate_keys -p` preflight verifies that the candidate's `SUPublicEDKey` matches the selected account without revealing a private key.

The script also runs `apps/macos/scripts/verify-appcast.swift` against the generated feed and archive, then verifies that both tampered cases fail. This verifier reads only the public key from the candidate's Info.plist; it never needs the private key. The live vendor CLI independently authenticates the feed and enclosure through that same embedded public key.

Sparkle 2.10's source rejects `--probe` combined with `--application` or `--check-immediately`. Its usage label `bundle` denotes the required positional bundle path; it is not a literal subcommand. The script therefore invokes the supported probe form:

```text
sparkle <old.app> --probe --feed-url <loopback-appcast> --user-agent-name ...
```

and invokes installation without `--probe`:

```text
sparkle <old.app> --check-immediately --feed-url <loopback-appcast> --user-agent-name ...
```

The full before/after Preferences plist is retained. Sparkle necessarily creates `SUHasLaunchedBefore` and updates `SULastCheckTime` during an update check; a failed signed-feed check may also set `SUInitialFailedFeedSigningValidationDate` when the app enables Sparkle's expiry recovery. Those three documented Sparkle bookkeeping keys are the only allowed differences. Every other UserDefaults key and every byte of `appearance.json`, Themes, credentials, Space, Activity, and recovery must remain unchanged.

The script has a 60-second stop condition for the packaged snapshot and 180 seconds per CLI command. It preserves partial artifacts and writes `result.json` as `COMPLETED` or `FAILED`. It validates an empty, non-running synthetic target; it does not exercise unsaved-document save/cancel/relaunch behavior, which remains a separate GUI acceptance boundary.
