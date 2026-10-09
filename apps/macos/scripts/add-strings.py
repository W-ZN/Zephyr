#!/usr/bin/env python3
"""Add or update zh-Hans translations in Localizable.xcstrings: add-strings.py 'English=中文' ..."""
import json
import sys

path = "apps/macos/app/Localizable.xcstrings"
catalog = json.load(open(path, encoding="utf-8"))
for pair in sys.argv[1:]:
    key, value = pair.split("=", 1)
    catalog["strings"][key] = {"localizations": {"zh-Hans": {"stringUnit": {"state": "translated", "value": value}}}}
catalog["strings"] = dict(sorted(catalog["strings"].items()))
with open(path, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(",", " : "))
    f.write("\n")
