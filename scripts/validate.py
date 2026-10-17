#!/usr/bin/env python3
"""Check the homelab repo against the conventions in AGENTS.md.

Run from anywhere inside the repo:

    python scripts/validate.py                 # structure + compose + Komodo TOML checks
    python scripts/validate.py --check-images  # also confirm prebuilt images exist for
                                               # each host's CPU arch (needs docker CLI)

Exit code 0 = OK (warnings allowed), 1 = errors, 2 = couldn't run.
Requires Python 3.11+ and PyYAML (`pip install pyyaml`).
"""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

if sys.version_info < (3, 11):
    sys.exit("validate.py needs Python 3.11+ (for tomllib).")

import tomllib

try:
    import yaml
except ImportError:  # pragma: no cover
    print("PyYAML is missing. Install it with:  pip install pyyaml", file=sys.stderr)
    sys.exit(2)


REPO = Path(__file__).resolve().parent.parent
STRATEGIES = ("redeploy-always", "redeploy-if-changed")
SECRET_KEY_RE = re.compile(r"(PASSWORD|PASSWD|SECRET|TOKEN|API_?KEY|PRIVATE_?KEY|CREDENTIAL)", re.I)
VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-?+][^}]*)?\}")
PLACEHOLDER = "TODO(new_service)"
# Things a compose file may only do if it declares them under x-homelab.allow
# with a reason, so a human sees them in review.
ALLOWANCES = {
    "privileged": "privileged: true",
    "host-network": "network_mode: host",
    "host-pid": "pid: host",
    "docker-socket": "mounting the Docker socket",
    "host-path": "bind-mounting a host path outside ${APPDATA}",
    "devices": "passing host devices into the container",
    "capabilities": "cap_add",
    "no-healthcheck": "a long-running service without a healthcheck",
}


# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #

@dataclass
class Report:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def error(self, where: Path | str, msg: str) -> None:
        self.errors.append(f"{_rel(where)}: {msg}")

    def warn(self, where: Path | str, msg: str) -> None:
        self.warnings.append(f"{_rel(where)}: {msg}")


def _rel(p: Path | str) -> str:
    try:
        return Path(p).resolve().relative_to(REPO).as_posix()
    except ValueError:
        return str(p)


# --------------------------------------------------------------------------- #
# Loading
# --------------------------------------------------------------------------- #

def load_hosts() -> dict:
    with open(REPO / "hosts.toml", "rb") as f:
        return tomllib.load(f)


def discover_services(hosts: dict, report: Report) -> list[tuple[str, str, Path]]:
    """Return (host, service, dir) for every hosts/<host>/<service>/ directory."""
    found = []
    hosts_dir = REPO / "hosts"
    if not hosts_dir.is_dir():
        return found
    for host_dir in sorted(p for p in hosts_dir.iterdir() if p.is_dir()):
        if host_dir.name not in hosts["hosts"]:
            report.error(host_dir, f"unknown host '{host_dir.name}' (not in hosts.toml)")
            continue
        for svc_dir in sorted(p for p in host_dir.iterdir() if p.is_dir()):
            found.append((host_dir.name, svc_dir.name, svc_dir))
    return found


def parse_komodo_env(text: str) -> dict[str, str]:
    """Parse Komodo's `environment` block: KEY = value lines, # comments allowed."""
    env = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if " #" in line:
            line = line.split(" #", 1)[0].rstrip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


# --------------------------------------------------------------------------- #
# Compose helpers
# --------------------------------------------------------------------------- #

def iter_ports(spec) -> list[tuple[int, str]]:
    """Return [(host_port, proto)] published by one `ports:` entry."""
    out: list[tuple[int, str]] = []
    if isinstance(spec, dict):
        published = spec.get("published")
        proto = spec.get("protocol", "tcp")
        if published is None:
            return out
        return [(p, proto) for p in _expand_range(str(published))]
    if isinstance(spec, int):
        return out  # container port only, random host port
    text = str(spec)
    proto = "tcp"
    if "/" in text:
        text, proto = text.rsplit("/", 1)
    parts = text.split(":")
    if len(parts) == 1:
        return out
    host_part = parts[-2]  # handles "ip:host:container"
    if not host_part:
        return out
    return [(p, proto) for p in _expand_range(host_part)]


def _expand_range(text: str) -> list[int]:
    if "${" in text:
        return []
    if "-" in text:
        lo, hi = text.split("-", 1)
        return list(range(int(lo), int(hi) + 1))
    return [int(text)]


def iter_mounts(svc: dict) -> list[tuple[str, str]]:
    """Return [(kind, source)] for each volume: kind is bind|volume."""
    out = []
    for v in svc.get("volumes", []) or []:
        if isinstance(v, dict):
            kind = v.get("type", "volume")
            src = str(v.get("source", ""))
            if kind == "bind" or src.startswith(("/", ".", "${", "~")):
                out.append(("bind", src))
            elif src:
                out.append(("volume", src))
            continue
        text = str(v)
        if ":" not in text:
            continue  # anonymous volume
        src = text.split(":", 1)[0]
        if src.startswith(("/", ".", "${", "~")):
            out.append(("bind", src))
        else:
            out.append(("volume", src))
    return out


def image_is_pinned(image: str) -> tuple[bool, str | None]:
    """(pinned, problem). Variable tags count as pinned-with-a-warning."""
    if "@sha256:" in image:
        return True, None
    last = image.rsplit("/", 1)[-1]
    if ":" not in last:
        return False, "has no tag (implicitly :latest)"
    tag = last.split(":", 1)[1]
    if "${" in tag:
        return True, "tag comes from a variable; make sure it resolves to a pinned version"
    if tag in ("latest", "stable", "release", "main", "master", "edge", "nightly"):
        return False, f"uses floating tag ':{tag}'"
    return True, None


# --------------------------------------------------------------------------- #
# Checks
# --------------------------------------------------------------------------- #

def check_service(host: str, name: str, svc_dir: Path, hosts: dict, report: Report,
                  ports_by_host: dict, stack_names: dict, images_by_host: dict) -> None:
    host_cfg = hosts["hosts"][host]
    compose_path = svc_dir / "compose.yaml"
    toml_path = REPO / "komodo" / "stacks" / host / f"{name}.toml"

    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
        report.error(svc_dir, "service directory names must be lowercase letters, digits and dashes")
    if not compose_path.is_file():
        report.error(svc_dir, "missing compose.yaml")
        return
    if not toml_path.is_file():
        report.error(svc_dir, f"missing Komodo stack file {_rel(toml_path)} "
                              f"(run scripts/new_service.py or copy an existing one)")
    if not (svc_dir / "README.md").is_file():
        report.warn(svc_dir, "no README.md (purpose, URL, secrets, data paths)")

    for p in (compose_path, svc_dir / "Dockerfile", svc_dir / "README.md", toml_path):
        if p.is_file() and PLACEHOLDER in p.read_text(encoding="utf-8", errors="ignore"):
            report.error(p, f"still contains the scaffold placeholder '{PLACEHOLDER}'")

    compose_text = compose_path.read_text(encoding="utf-8")
    try:
        compose = yaml.safe_load(compose_text) or {}
    except yaml.YAMLError as e:
        report.error(compose_path, f"invalid YAML: {e}")
        return
    services = compose.get("services") or {}
    if not services:
        report.error(compose_path, "defines no services")
        return
    if "name" in compose:
        report.warn(compose_path, "top-level 'name:' is ignored; Komodo sets the project name from the stack name")

    # --- x-homelab allowances --------------------------------------------- #
    allow = (compose.get("x-homelab") or {}).get("allow") or {}
    if not isinstance(allow, dict):
        report.error(compose_path, "x-homelab.allow must be a mapping of allowance -> reason")
        allow = {}
    for key, reason in allow.items():
        if key not in ALLOWANCES:
            report.error(compose_path, f"unknown x-homelab allowance '{key}' "
                                       f"(valid: {', '.join(ALLOWANCES)})")
        elif not str(reason or "").strip():
            report.error(compose_path, f"x-homelab allowance '{key}' needs a reason string")
        else:
            report.warn(compose_path, f"REVIEW: allows {ALLOWANCES[key]} - {reason}")

    def need(key: str, svc_name: str) -> None:
        if key not in allow:
            report.error(compose_path, f"service '{svc_name}': {ALLOWANCES[key]} is not allowed "
                                       f"unless declared under x-homelab.allow.{key} with a reason")

    builds = False
    repo_mounts: list[str] = []

    for svc_name, svc in services.items():
        svc = svc or {}
        if "build" in svc:
            builds = True
        elif "image" not in svc:
            report.error(compose_path, f"service '{svc_name}' has neither image nor build")
        else:
            pinned, problem = image_is_pinned(str(svc["image"]))
            if not pinned:
                report.error(compose_path, f"service '{svc_name}' image '{svc['image']}' {problem}; pin a version")
            elif problem:
                report.warn(compose_path, f"service '{svc_name}' image '{svc['image']}' {problem}")
            images_by_host.setdefault(host, set()).add(str(svc["image"]))

        restart = svc.get("restart")
        one_shot = str(restart).lower() in ("no", "false") or svc.get("deploy", {}).get("restart_policy", {}).get("condition") == "none"
        if restart is None:
            report.error(compose_path, f"service '{svc_name}' has no restart policy (use unless-stopped)")

        hc = svc.get("healthcheck")
        if not one_shot and (hc is None or hc.get("disable")):
            if "no-healthcheck" not in allow:
                report.error(compose_path, f"service '{svc_name}' has no healthcheck")

        if svc.get("privileged"):
            need("privileged", svc_name)
        if str(svc.get("network_mode", "")) == "host":
            need("host-network", svc_name)
        if str(svc.get("pid", "")) == "host":
            need("host-pid", svc_name)
        if svc.get("devices"):
            need("devices", svc_name)
        if svc.get("cap_add"):
            need("capabilities", svc_name)

        for kind, src in iter_mounts(svc):
            if kind == "volume":
                report.warn(compose_path, f"service '{svc_name}' uses named volume '{src}'; "
                                          f"prefer ${{APPDATA}}/... so data lands in the backed-up appdata tree")
                continue
            if "docker.sock" in src:
                need("docker-socket", svc_name)
            elif src.startswith(("${APPDATA}", "$APPDATA")):
                pass
            elif src.startswith("."):
                repo_mounts.append(src)
            else:
                need("host-path", svc_name)

        for spec in svc.get("ports", []) or []:
            try:
                for port, proto in iter_ports(spec):
                    ports_by_host.setdefault(host, {}).setdefault((port, proto), []).append(f"{name}/{svc_name}")
            except ValueError:
                report.error(compose_path, f"service '{svc_name}' has an unparseable port '{spec}'")

        env = svc.get("environment") or {}
        items = env.items() if isinstance(env, dict) else (
            (e.split("=", 1)[0], e.split("=", 1)[1] if "=" in e else "") for e in env)
        for key, value in items:
            value = "" if value is None else str(value)
            if SECRET_KEY_RE.search(str(key)) and value and not value.startswith("${"):
                report.error(compose_path, f"service '{svc_name}' sets {key} to a literal value; "
                                           f"use ${{{key}}} and put [[SECRET]] in the stack's environment")

    for section in ("configs", "secrets"):
        for cname, cfg in (compose.get(section) or {}).items():
            src = str((cfg or {}).get("file", ""))
            if src.startswith("."):
                repo_mounts.append(src)
            elif src:
                report.error(compose_path, f"{section}.{cname} reads '{src}' from outside the service directory")

    for src in repo_mounts:
        resolved = (svc_dir / src).resolve()
        if not str(resolved).startswith(str(svc_dir.resolve())):
            report.error(compose_path, f"mount source '{src}' escapes the service directory")

    # --- Stack TOML --------------------------------------------------------- #
    if not toml_path.is_file():
        return
    try:
        with open(toml_path, "rb") as f:
            doc = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        report.error(toml_path, f"invalid TOML: {e}")
        return

    stacks = doc.get("stack", [])
    other = [k for k in doc if k != "stack"]
    if other:
        report.error(toml_path, f"stack files may only declare [[stack]] (found: {', '.join(other)})")
    if len(stacks) != 1:
        report.error(toml_path, f"must declare exactly one [[stack]] (found {len(stacks)})")
        return
    stack = stacks[0]
    cfg = stack.get("config", {})
    git = hosts["git"]

    if stack.get("name") != name:
        report.error(toml_path, f"stack name '{stack.get('name')}' must equal the directory name '{name}'")
    if name in stack_names:
        report.error(toml_path, f"stack name '{name}' is also used by {stack_names[name]}; names must be unique across hosts")
    stack_names[name] = _rel(toml_path)

    tags = stack.get("tags", [])
    strategy = [t for t in tags if t in STRATEGIES]
    if "git" not in tags:
        report.error(toml_path, "tags must include 'git' (the sync only manages git-tagged resources)")
    if host not in tags:
        report.error(toml_path, f"tags must include the host '{host}'")
    if len(strategy) != 1:
        report.error(toml_path, f"tags must include exactly one of: {', '.join(STRATEGIES)}")
    if stack.get("deploy"):
        report.warn(toml_path, "deploy = true is unnecessary; the deploy-on-push procedure handles deploys")

    expected = {
        "server": host,
        "git_provider": git["provider"],
        "git_https": git["https"],
        "git_account": git["account"],
        "repo": git["repo"],
        "branch": git["branch"],
        "run_directory": f"hosts/{host}/{name}",
    }
    for key, want in expected.items():
        if cfg.get(key) != want:
            report.error(toml_path, f"config.{key} is {cfg.get(key)!r}, expected {want!r}")

    file_paths = cfg.get("file_paths", ["compose.yaml"])
    if "compose.yaml" not in file_paths:
        report.error(toml_path, "config.file_paths must include compose.yaml")
    for fp in file_paths:
        if not (svc_dir / fp).is_file():
            report.error(toml_path, f"config.file_paths lists '{fp}', which doesn't exist in {_rel(svc_dir)}")

    if builds:
        if strategy and strategy[0] != "redeploy-always":
            report.error(toml_path, "stacks that build from source must be tagged redeploy-always "
                                    "(Komodo's change detection can't see source changes)")
        if cfg.get("run_build") is not True:
            report.error(toml_path, "stacks that build from source need run_build = true")
        if cfg.get("auto_pull", True) is not False:
            report.error(toml_path, "stacks that build from source need auto_pull = false")

    if strategy == ["redeploy-if-changed"] and repo_mounts:
        tracked = {posixpath.normpath(str(c.get("path", "") if isinstance(c, dict) else c))
                   for c in cfg.get("config_files", [])}
        for src in repo_mounts:
            rel = posixpath.normpath(src)
            if (svc_dir / src).is_dir():
                report.error(toml_path, f"mounts repo directory '{src}' but is redeploy-if-changed; "
                                        f"Komodo can't diff a directory. Tag it redeploy-always instead")
            elif rel not in tracked:
                report.error(toml_path, f"mounts repo file '{src}' but it isn't in config.config_files, "
                                        f"so edits to it would never deploy. Add "
                                        f"{{ path = \"{rel}\", requires = \"Redeploy\" }}")

    env = parse_komodo_env(cfg.get("environment", ""))
    want_appdata = f"{host_cfg['appdata'].rstrip('/')}/{name}"
    if env.get("APPDATA") != want_appdata:
        report.error(toml_path, f"environment APPDATA is {env.get('APPDATA')!r}, expected {want_appdata!r}")
    for key, value in env.items():
        if SECRET_KEY_RE.search(key) and not re.fullmatch(r"\[\[[A-Za-z0-9_]+\]\]", value):
            report.error(toml_path, f"environment {key} must be a Komodo secret reference like [[{key}]], "
                                    f"not a literal value")

    for var, modifier in VAR_RE.findall(compose_text):
        if var not in env and not modifier.startswith((":-", "-")):
            report.warn(compose_path, f"uses ${{{var}}} but the stack environment doesn't define it")


def check_orphan_stacks(services: list[tuple[str, str, Path]], report: Report) -> None:
    known = {(h, s) for h, s, _ in services}
    stacks_dir = REPO / "komodo" / "stacks"
    if not stacks_dir.is_dir():
        return
    for toml_path in stacks_dir.rglob("*.toml"):
        rel = toml_path.relative_to(stacks_dir)
        if len(rel.parts) != 2:
            report.error(toml_path, "stack files must live at komodo/stacks/<host>/<service>.toml")
            continue
        if (rel.parts[0], toml_path.stem) not in known:
            report.error(toml_path, f"no matching service directory hosts/{rel.parts[0]}/{toml_path.stem}/")


def check_ports(hosts: dict, ports_by_host: dict, report: Report) -> None:
    for host, ports in ports_by_host.items():
        reserved = set(hosts["hosts"][host].get("reserved_ports", []))
        for (port, proto), users in sorted(ports.items()):
            if len(users) > 1:
                report.error(f"hosts/{host}", f"host port {port}/{proto} is published by more than one service: "
                                              f"{', '.join(users)}")
            if port in reserved:
                report.error(f"hosts/{host}", f"host port {port}/{proto} ({', '.join(users)}) is reserved "
                                              f"in hosts.toml")


def check_images(hosts: dict, images_by_host: dict, report: Report) -> None:
    if not shutil.which("docker"):
        report.warn("--check-images", "docker CLI not found; skipped image architecture checks")
        return
    for host, images in images_by_host.items():
        arch = hosts["hosts"][host]["arch"]
        for image in sorted(images):
            if "${" in image:
                continue
            proc = subprocess.run(["docker", "manifest", "inspect", "-v", image],
                                  capture_output=True, text=True)
            if proc.returncode != 0:
                report.error(f"hosts/{host}", f"image '{image}' not found or not accessible: "
                                              f"{proc.stderr.strip().splitlines()[-1] if proc.stderr else ''}")
                continue
            data = json.loads(proc.stdout)
            entries = data if isinstance(data, list) else [data]
            archs = {((e.get("Descriptor") or {}).get("platform") or {}).get("architecture") for e in entries}
            if arch not in archs:
                report.error(f"hosts/{host}", f"image '{image}' has no {arch} build (has: "
                                              f"{', '.join(sorted(a for a in archs if a)) or 'unknown'})")


# --------------------------------------------------------------------------- #

def collect_used_ports(host: str) -> set[int]:
    """Used by new_service.py to pick a free port."""
    hosts = load_hosts()
    used = set(hosts["hosts"][host].get("reserved_ports", []))
    host_dir = REPO / "hosts" / host
    for compose_path in host_dir.glob("*/compose.yaml"):
        try:
            compose = yaml.safe_load(compose_path.read_text(encoding="utf-8")) or {}
        except yaml.YAMLError:
            continue
        for svc in (compose.get("services") or {}).values():
            for spec in (svc or {}).get("ports", []) or []:
                try:
                    used.update(p for p, _ in iter_ports(spec))
                except ValueError:
                    pass
    return used


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check-images", action="store_true",
                        help="verify prebuilt images exist for each host's architecture (needs docker)")
    args = parser.parse_args()

    report = Report()
    try:
        hosts = load_hosts()
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"Can't read hosts.toml: {e}", file=sys.stderr)
        return 2

    services = discover_services(hosts, report)
    ports_by_host: dict = {}
    stack_names: dict = {}
    images_by_host: dict = {}
    for host, name, svc_dir in services:
        check_service(host, name, svc_dir, hosts, report, ports_by_host, stack_names, images_by_host)
    check_orphan_stacks(services, report)
    check_ports(hosts, ports_by_host, report)
    if args.check_images:
        check_images(hosts, images_by_host, report)

    for w in report.warnings:
        print(f"WARN  {w}")
    for e in report.errors:
        print(f"ERROR {e}")
    print(f"\n{len(services)} service(s) checked: {len(report.errors)} error(s), {len(report.warnings)} warning(s).")
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())
