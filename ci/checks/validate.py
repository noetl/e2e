#!/usr/bin/env python3
"""Pre-merge validation for noetl/e2e (noetl/ai-meta#375).

This repo's only workflow published a container image on push to main, so
nothing gated a pull request: a broken fixture, manifest or script merged
clean and surfaced when someone ran the suite.

Two properties, both learned elsewhere in the fleet and worth preserving:

* **Populations are DISCOVERED, never enumerated.**  A hardcoded file list is
  a representation that drifts the moment someone adds a fixture, and a check
  that silently stops covering half the repo reports the same green as a
  healthy one.
* **Every check prints its denominator and FAILS below a floor.**  "0
  failures" is also what a check that examined nothing looks like, so a broken
  glob or a bad checkout is a red build rather than a clean one.

The Docusaurus site is NOT built here -- that is a separate workflow step, so
a build failure and a fixture failure are distinguishable in the job log
rather than hidden behind one red X.
"""
from __future__ import annotations
import os
import subprocess
import sys

MIN = {"yaml": 120, "shell": 25, "python": 5}


def tracked(*globs: str) -> list[str]:
    r = subprocess.run(["git", "ls-files", *globs], capture_output=True, text=True)
    r.check_returncode()
    return [p for p in r.stdout.split("\n") if p]


def is_helm_template(path: str) -> bool:
    """Go-templated chart files are not valid YAML by design.  Identified by a
    sibling Chart.yaml rather than by a path pattern, so adding or moving a
    chart cannot quietly drop it from coverage."""
    parts = path.split("/")
    if "templates" not in parts:
        return False
    root = "/".join(parts[: parts.index("templates")])
    return os.path.exists(os.path.join(root, "Chart.yaml"))


def report(name: str, population: int, failures: list[str]) -> bool:
    floor = MIN.get(name, 1)
    print(f"\n── {name}: examined {population}, failures {len(failures)}")
    if population < floor:
        print(f"   ✗ POPULATION {population} IS BELOW THE FLOOR OF {floor}.")
        print("     The check did not look at what it claims to cover.  Treating a")
        print("     result computed from too few files as a pass is how a gate goes")
        print("     inert while still reporting green.")
        return False
    for f in failures:
        print(f"   ✗ {f}")
    if not failures:
        print("   ✓ clean")
    return not failures


def check_yaml() -> bool:
    try:
        import yaml
    except ImportError:
        print("── yaml: PyYAML not installed; cannot validate")
        return False
    everything = tracked("*.yaml", "*.yml")
    files = [f for f in everything if not is_helm_template(f)]
    if len(everything) != len(files):
        print(f"   (excluded {len(everything) - len(files)} Helm templates)")
    failures = []
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                list(yaml.safe_load_all(fh))
        except Exception as exc:
            failures.append(f"{f}: {str(exc).splitlines()[0]}")
    return report("yaml", len(files), failures)


def check_shell() -> bool:
    files = tracked("*.sh")
    failures = []
    for f in files:
        r = subprocess.run(["bash", "-n", f], capture_output=True, text=True)
        if r.returncode != 0:
            err = r.stderr.strip().splitlines()
            failures.append(f"{f}: {err[0] if err else 'syntax error'}")
    return report("shell", len(files), failures)


def check_python() -> bool:
    files = tracked("*.py")
    failures = []
    for f in files:
        r = subprocess.run([sys.executable, "-m", "py_compile", f], capture_output=True, text=True)
        if r.returncode != 0:
            tail = r.stderr.strip().splitlines()
            failures.append(f"{f}: {tail[-1] if tail else 'compile error'}")
    ok = report("python", len(files), failures)
    subprocess.run(["find", ".", "-name", "__pycache__", "-prune", "-exec", "rm", "-rf", "{}", "+"],
                   capture_output=True)
    return ok


def main() -> int:
    print("noetl/e2e pre-merge validation (noetl/ai-meta#375)")
    results = {"yaml": check_yaml(), "shell": check_shell(), "python": check_python()}
    print("\n" + "─" * 60)
    for name, ok in results.items():
        print(f"  {name:<8} {'OK' if ok else 'FAIL'}")
    failed = [n for n, ok in results.items() if not ok]
    if failed:
        print(f"\nFAILED: {', '.join(failed)}")
        return 1
    print("\nAll checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
