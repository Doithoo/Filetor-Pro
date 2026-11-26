#!/usr/bin/env python3
"""Validate bilingual resources and literal L10n.tr coverage before building."""
from collections import Counter
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1] / "Filetor"


def string_end(source, start):
    index = start + 1
    while index < len(source):
        if source[index] == "\\":
            if source[index + 1:index + 2] == "(":
                index = expression_end(source, index + 2)
                continue
            index += 2
            continue
        if source[index] == '"':
            return index + 1
        index += 1
    raise ValueError(f"Unterminated string at {start}")


def expression_end(source, index):
    depth = 1
    while index < len(source):
        if source[index] == '"':
            index = string_end(source, index)
            continue
        if source[index] == "(":
            depth += 1
        if source[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    raise ValueError("Unterminated interpolation")


def tokens(source):
    """Read ordinary Swift literals, skipping comments and interpolated code."""
    index = 0
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = end if end >= 0 else len(source)
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index)
            index = end + 2 if end >= 0 else len(source)
            continue
        if source[index] == '"':
            end = string_end(source, index)
            if not source.startswith('"""', index) and (index == 0 or source[index - 1] != "#"):
                yield index, source[index:end]
            index = end
        else:
            index += 1


def message_key(literal):
    source = literal[1:-1]
    result, index, argument = "", 0, 0
    escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
    while index < len(source):
        if source.startswith("\\(", index):
            index = expression_end(source, index + 2)
            result += "{" + str(argument) + "}"
            argument += 1
        elif source[index] == "\\":
            escape = source[index + 1]
            result += escapes.get(escape, "\\" + escape)
            index += 2
        else:
            result += source[index]
            index += 1
    return re.sub(r"\\u\{([0-9a-fA-F]+)\}", lambda m: chr(int(m[1], 16)), result)


def read_strings(path):
    subprocess.run(["plutil", "-lint", str(path)], check=True, capture_output=True)
    entries = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("/*"):
            continue
        match = re.fullmatch(r'("(?:\\.|[^"\\])*") = ("(?:\\.|[^"\\])*");', line)
        if not match:
            raise ValueError(f"Invalid resource line in {path}: {line}")
        key, value = (json.loads(x) for x in match.groups())
        if key in entries:
            raise ValueError(f"Duplicate key: {key}")
        entries[key] = value
    return entries


def main():
    english = read_strings(ROOT / "en.lproj/Localizable.strings")
    chinese = read_strings(ROOT / "zh-Hans.lproj/Localizable.strings")
    assert english.keys() == chinese.keys(), "Language key sets differ"
    neutral = {"AirDrop", "PNG", "JPEG", "HEIC", "TIFF", "WebP", "PDF",
               "Filetor Pro {0}", "pdf, jpg, txt", "psd, ai, svg", "px", "smb://server/share", "{0} {1}"}
    for key, value in chinese.items():
        assert english[key] == key, f"English fallback differs from source: {key}"
        assert value.strip(), f"Empty translation: {key}"
        assert key in neutral or value != key, f"Untranslated Chinese key: {key}"
        assert Counter(re.findall(r"\{\d+\}", key)) == Counter(re.findall(r"\{\d+\}", value)), f"Placeholder mismatch: {key}"
    used = set()
    for path in ROOT.glob("*.swift"):
        source = path.read_text()
        for start, literal in tokens(source):
            if source[max(0, start - 8):start] == "L10n.tr(":
                key = message_key(literal)
                assert key in english, f"Missing translation in {path.name}: {key}"
                used.add(key)
    print(f"Localization: {len(english)} bilingual keys, {len(used)} literal keys covered; placeholders valid")


if __name__ == "__main__":
    main()
