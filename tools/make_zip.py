"""Pakker addonen til deling: dist/GuildCrafters-<version>.zip med mappen GuildCrafters/ i roden.

Kør: python tools/make_zip.py
Modtageren pakker zip'en ud i World of Warcraft\\_anniversary_\\Interface\\AddOns\\.
"""
import os
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(ROOT, "GuildCrafters")


def version():
    for line in open(os.path.join(ADDON, "GuildCrafters.toc"), encoding="utf-8"):
        if line.startswith("## Version:"):
            return line.split(":", 1)[1].strip()
    raise SystemExit("Ingen ## Version i GuildCrafters.toc")


def main():
    out_dir = os.path.join(ROOT, "dist")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"GuildCrafters-{version()}.zip")
    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for folder, _, files in os.walk(ADDON):
            for name in sorted(files):
                if name == "GuildCraftersTest.toc":     # testudgavens .toc skal ikke med ud
                    continue
                path = os.path.join(folder, name)
                z.write(path, os.path.relpath(path, ROOT).replace(os.sep, "/"))
                count += 1
    print(f"{out} ({count} filer, {os.path.getsize(out) // 1024} KB)")


if __name__ == "__main__":
    main()
