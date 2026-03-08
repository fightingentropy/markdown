#!/usr/bin/env python3

import os
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "Usage: rewrite_appcast_for_github_releases.py <appcast-path> <owner/repo>",
            file=sys.stderr,
        )
        return 1

    appcast_path = sys.argv[1]
    repo = sys.argv[2]

    tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel = root.find("channel")
    if channel is None:
        print("Appcast channel node not found", file=sys.stderr)
        return 1

    short_version_key = f"{{{SPARKLE_NS}}}shortVersionString"
    deltas_key = f"{{{SPARKLE_NS}}}deltas"

    for item in channel.findall("item"):
        short_version = item.findtext(short_version_key) or item.findtext("title")
        if not short_version:
            continue

        asset_base = f"https://github.com/{repo}/releases/download/v{short_version}"

        for enclosure in item.findall("enclosure"):
            filename = os.path.basename(enclosure.attrib["url"])
            enclosure.set("url", f"{asset_base}/{filename}")

        deltas = item.find(deltas_key)
        if deltas is None:
            continue

        for enclosure in deltas.findall("enclosure"):
            filename = os.path.basename(enclosure.attrib["url"])
            enclosure.set("url", f"{asset_base}/{filename}")

    tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
