"""package.py — stage ex/echo_data as a self-contained Hex package.

In the repository the NIF crate depends on native/rust's crates by relative path. A Hex tarball
cannot reach them, so the stage copies them into native/vendor/, resolves their workspace-
inherited manifest fields from native/rust/Cargo.toml, and points the NIF's dependencies there.
The repository's own files are never modified.

    python3 ex/package.py <stage_dir>
"""

from __future__ import annotations

import pathlib
import re
import shutil
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "ex" / "echo_data"
CRATES = ROOT / "native" / "rust" / "crates"
VENDORED = ("brd14", "brd14-data")
SKIP = shutil.ignore_patterns("_build", "deps", "target", "*.so", "*.dylib", "erl_crash.dump")


def resolve_workspace_fields(manifest: str, workspace_package: dict) -> str:
    """`key.workspace = true` -> `key = <the workspace value>`; drop `[lints] workspace = true`."""

    def sub(m: re.Match) -> str:
        key = m.group(1)
        if key not in workspace_package:
            raise SystemExit(f"package.py: {key}.workspace has no value in [workspace.package]")
        value = workspace_package[key]
        return f"{key} = {value!r}".replace("'", '"') if isinstance(value, str) else f"{key} = {value}"

    manifest = re.sub(r"^([a-z-]+)\.workspace\s*=\s*true\s*$", sub, manifest, flags=re.M)
    return re.sub(r"^\[lints\]\s*\nworkspace\s*=\s*true\s*\n", "", manifest, flags=re.M)


def main() -> None:
    stage = pathlib.Path(sys.argv[1]).resolve()
    if stage.exists():
        shutil.rmtree(stage)
    shutil.copytree(APP, stage, ignore=SKIP)

    workspace = tomllib.loads((ROOT / "native" / "rust" / "Cargo.toml").read_text())["workspace"]["package"]
    vendor = stage / "native" / "vendor"
    for name in VENDORED:
        shutil.copytree(CRATES / name, vendor / name, ignore=SKIP)
        cargo = vendor / name / "Cargo.toml"
        cargo.write_text(resolve_workspace_fields(cargo.read_text(), workspace))

    nif = stage / "native" / "echo_data_nif" / "Cargo.toml"
    text = nif.read_text()
    for name in VENDORED:
        old = f'path = "../../../../native/rust/crates/{name}"'
        if old not in text:
            raise SystemExit(f"package.py: the NIF manifest no longer names {old}")
        text = text.replace(old, f'path = "../vendor/{name}"')
    nif.write_text(text)
    print(f"package.py: staged {stage.relative_to(ROOT) if stage.is_relative_to(ROOT) else stage}"
          f" with vendored {', '.join(VENDORED)}")


if __name__ == "__main__":
    main()
