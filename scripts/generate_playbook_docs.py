#!/usr/bin/env python3
"""Generate Docusaurus playbook inventory pages from fixture YAML files."""

from __future__ import annotations

import collections
import pathlib
import re
from typing import Any

import yaml


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
PLAYBOOK_ROOT = REPO_ROOT / "fixtures" / "playbooks"
DOCS_ROOT = REPO_ROOT / "docs" / "playbooks"
CATEGORIES_ROOT = DOCS_ROOT / "categories"


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "root"


def load_yaml(path: pathlib.Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    return data if isinstance(data, dict) else {}


def first_category(relative: pathlib.Path) -> str:
    if len(relative.parts) == 1:
        return "root"
    return relative.parts[0]


def step_tools(workflow: Any) -> str:
    tools: set[str] = set()
    if not isinstance(workflow, list):
        return ""
    for step in workflow:
        if not isinstance(step, dict):
            continue
        tool = step.get("tool")
        if isinstance(tool, dict):
            kind = tool.get("kind") or tool.get("type")
            if kind:
                tools.add(str(kind))
    return ", ".join(sorted(tools))


def metadata_for(path: pathlib.Path) -> dict[str, str]:
    data = load_yaml(path)
    metadata = data.get("metadata") if isinstance(data.get("metadata"), dict) else {}
    relative = path.relative_to(REPO_ROOT).as_posix()
    playbook_relative = path.relative_to(PLAYBOOK_ROOT)

    catalog_path = str(metadata.get("path") or metadata.get("name") or relative)
    name = str(metadata.get("name") or pathlib.Path(catalog_path).name or path.stem)
    description = str(metadata.get("description") or "")
    category = first_category(playbook_relative)
    tools = step_tools(data.get("workflow"))

    return {
        "name": name,
        "path": catalog_path,
        "file": relative,
        "category": category,
        "description": description,
        "tools": tools,
    }


def table_row(item: dict[str, str]) -> str:
    description = escape_markdown_cell(item["description"]) if item["description"] else "-"
    tools = escape_markdown_cell(item["tools"]) if item["tools"] else "-"
    return f"| `{escape_code(item['path'])}` | `{escape_code(item['file'])}` | {description} | {tools} |"


def escape_code(value: str) -> str:
    return value.replace("`", "\\`")


def escape_markdown_cell(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace("|", "\\|")
        .replace("{", "\\{")
        .replace("}", "\\}")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\n", " ")
    )


def write_index(items: list[dict[str, str]]) -> None:
    categories = collections.Counter(item["category"] for item in items)
    lines = [
        "---",
        "id: index",
        "title: Playbook Inventory",
        "---",
        "",
        f"Generated from `{PLAYBOOK_ROOT.relative_to(REPO_ROOT).as_posix()}`.",
        "",
        f"Total playbooks: **{len(items)}**.",
        "",
        "## Categories",
        "",
        "| Category | Playbooks |",
        "| --- | ---: |",
    ]
    for category, count in sorted(categories.items()):
        label = category.replace("_", " ").replace("-", " ").title()
        lines.append(f"| [{label}](./categories/{slugify(category)}) | {count} |")

    lines.extend(
        [
            "",
            "## All Playbooks",
            "",
            "| Catalog path | Fixture file | Description | Tools |",
            "| --- | --- | --- | --- |",
        ]
    )
    lines.extend(table_row(item) for item in items)
    (DOCS_ROOT / "index.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_category_pages(items: list[dict[str, str]]) -> None:
    by_category: dict[str, list[dict[str, str]]] = collections.defaultdict(list)
    for item in items:
        by_category[item["category"]].append(item)

    for category, category_items in sorted(by_category.items()):
        label = category.replace("_", " ").replace("-", " ").title()
        lines = [
            "---",
            f"id: {slugify(category)}",
            f"title: {label}",
            "---",
            "",
            f"Playbooks in `{category}`.",
            "",
            "| Catalog path | Fixture file | Description | Tools |",
            "| --- | --- | --- | --- |",
        ]
        lines.extend(table_row(item) for item in category_items)
        (CATEGORIES_ROOT / f"{slugify(category)}.md").write_text(
            "\n".join(lines) + "\n", encoding="utf-8"
        )


def main() -> None:
    CATEGORIES_ROOT.mkdir(parents=True, exist_ok=True)
    for old_page in CATEGORIES_ROOT.glob("*.md"):
        old_page.unlink()

    items = sorted(
        (metadata_for(path) for path in PLAYBOOK_ROOT.rglob("*.yaml")),
        key=lambda item: (item["category"], item["path"], item["file"]),
    )

    write_index(items)
    write_category_pages(items)


if __name__ == "__main__":
    main()
