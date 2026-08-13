#!/usr/bin/env python3
"""Sync Azure SQL server (embedded) firewall rules from DB_FIREWALL_CIDRS.

Accepts CIDRs (e.g. 35.94.1.248/32) and start-end ranges
(e.g. 0.0.0.1-255.255.255.254) mixed in the same list.

Complementary to forgedb-firewall-rules/azure-firewall-rule.py (NSG).
This script manages PaaS Azure SQL server firewall rules via az CLI.
"""

from __future__ import annotations

import importlib.util
import ipaddress
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Any

import typer

# --- load bash_utils/cmd-wrapper-helpers.py (hyphenated filename) ---
_REPO_ROOT = Path(__file__).resolve().parent.parent
_CMD_HELPERS = _REPO_ROOT / "bash_utils" / "cmd-wrapper-helpers.py"


def _load_cmd_module():
    spec = importlib.util.spec_from_file_location("cmd_wrapper_helpers", _CMD_HELPERS)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load CMD helpers from {_CMD_HELPERS}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_cmd_mod = _load_cmd_module()
CMD = _cmd_mod.CMD
CmdConfig = _cmd_mod.CmdConfig

app = typer.Typer(add_completion=False)

_PUBLIC_IP_URLS = (
    "https://api.ipify.org",
    "https://ifconfig.me/ip",
)


@dataclass(frozen=True)
class ProposedRule:
    cidr: str
    name: str
    start_ip: str
    end_ip: str


def split_specs(raw: str) -> list[str]:
    """Split comma/whitespace separated CIDR or start-end range specs."""
    return [c for c in re.split(r"[\s,]+", raw.strip()) if c]


def rule_name_for_spec(spec: str) -> str:
    """Stable Azure rule name from CIDR or start-end range (./- → _)."""
    return re.sub(r"[./\-]", "_", spec.strip())


_IP_RANGE_RE = re.compile(
    r"^(?P<start>(?:\d{1,3}\.){3}\d{1,3})-(?P<end>(?:\d{1,3}\.){3}\d{1,3})$"
)


def spec_to_ip_range(spec: str) -> tuple[str, str]:
    """Map a CIDR or start-end range to Azure firewall start/end IPs.

    Examples:
      35.94.1.248/32           → (35.94.1.248, 35.94.1.248)
      0.0.0.1-255.255.255.254  → (0.0.0.1, 255.255.255.254)
    """
    text = spec.strip()
    m = _IP_RANGE_RE.match(text)
    if m:
        start = ipaddress.IPv4Address(m.group("start"))
        end = ipaddress.IPv4Address(m.group("end"))
        if int(start) > int(end):
            raise ValueError(f"range start {start} is after end {end}")
        return str(start), str(end)
    return cidr_to_ip_range(text)


def cidr_to_ip_range(cidr: str) -> tuple[str, str]:
    """Map CIDR to Azure firewall start/end IPs (ipcalc HostMin/HostMax intent)."""
    net = ipaddress.IPv4Network(cidr.strip(), strict=False)
    if net.prefixlen == 32:
        addr = str(net.network_address)
        return addr, addr
    # Usable hosts when available; otherwise network/broadcast (tiny nets).
    hosts = list(net.hosts())
    if hosts:
        return str(hosts[0]), str(hosts[-1])
    return str(net.network_address), str(net.broadcast_address)


def _sanitize_dbx_local(local_part: str) -> str:
    """firstname.lastname → firstnamelastname (same strip as WHOAMI on local part)."""
    return re.sub(r"[.\-_]", "", local_part.strip().lower())


def _dbx_username_from_cli() -> str:
    """Fallback: databricks current-user me → .userName."""
    cfg = CmdConfig(exit_on_error="PRINT_EXIT")
    rc = CMD("databricks", "current-user", "me", config=cfg)
    if rc != 0:
        raise RuntimeError("databricks current-user me failed")
    stdout_path = Path(f"/tmp/databricks_stdout.{os.getpid()}")
    payload = json.loads(stdout_path.read_text(encoding="utf-8"))
    user = payload.get("userName") or ""
    if not user:
        raise RuntimeError("databricks current-user me returned empty userName")
    return str(user)


def resolve_dbx_local_part() -> str:
    """Databricks email local-part (firstname.lastname), not OS WHOAMI."""
    local = os.environ.get("DBX_USERNAME_NO_DOMAIN", "").strip()
    if not local:
        full = os.environ.get("DBX_USERNAME", "").strip()
        if full:
            local = full.split("@", 1)[0]
    if not local:
        full = _dbx_username_from_cli()
        local = full.split("@", 1)[0]
    if not local:
        raise RuntimeError("cannot resolve Databricks username for VPN rule name")
    return local


def vpn_rule_name() -> str:
    """e.g. robert.lee@… → robertlee_vpn (never hard-coded)."""
    return f"{_sanitize_dbx_local(resolve_dbx_local_part())}_vpn"


def detect_public_ipv4() -> str:
    """Resolve public IPv4 via curl; try ipify then ifconfig.me."""
    last_err = ""
    for url in _PUBLIC_IP_URLS:
        try:
            p = subprocess.run(
                ["curl", "-4", "-fsS", url],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
            if p.returncode != 0:
                last_err = p.stderr.strip() or f"curl rc={p.returncode}"
                continue
            candidate = p.stdout.strip()
            ip = ipaddress.IPv4Address(candidate)
            return str(ip)
        except (ValueError, subprocess.TimeoutExpired, FileNotFoundError) as exc:
            last_err = str(exc)
            continue
    raise RuntimeError(f"could not detect public IPv4 ({last_err})")


def load_existing_rules(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data is None:
        return []
    if not isinstance(data, list):
        raise typer.BadParameter(f"--existing-rules must be a JSON array, got {type(data).__name__}")
    return data


def existing_indexes(
    rules: list[dict[str, Any]],
) -> tuple[set[str], set[tuple[str, str]], dict[str, tuple[str, str]]]:
    names: set[str] = set()
    ranges: set[tuple[str, str]] = set()
    by_name: dict[str, tuple[str, str]] = {}
    for rule in rules:
        name = rule.get("name")
        start = rule.get("startIpAddress") or rule.get("start_ip_address")
        end = rule.get("endIpAddress") or rule.get("end_ip_address")
        if name:
            names.add(str(name))
        if start and end:
            ranges.add((str(start), str(end)))
            if name:
                by_name[str(name)] = (str(start), str(end))
    return names, ranges, by_name


def build_proposed(specs: list[str]) -> list[ProposedRule]:
    proposed: list[ProposedRule] = []
    for spec in specs:
        try:
            start, end = spec_to_ip_range(spec)
        except ValueError as exc:
            print(f"Skipping invalid CIDR/range: {spec!r} ({exc})", file=sys.stderr)
            continue
        proposed.append(
            ProposedRule(
                cidr=spec,
                name=rule_name_for_spec(spec),
                start_ip=start,
                end_ip=end,
            )
        )
    return proposed


def resolve_resource_group(resource_group: str | None) -> str:
    if resource_group:
        return resource_group
    p = subprocess.run(
        ["az", "config", "get", "defaults.group", "-o", "json"],
        capture_output=True,
        text=True,
        check=False,
    )
    if p.returncode != 0 or not p.stdout.strip():
        raise typer.BadParameter("resource group required (pass -g or set az defaults.group)")
    payload = json.loads(p.stdout)
    value = payload.get("value") if isinstance(payload, dict) else None
    if not value:
        raise typer.BadParameter("az defaults.group is empty; pass --resource-group")
    return str(value)


def _create_rule(
    *,
    rule: ProposedRule,
    server: str,
    resource_group: str,
    cfg: Any,
) -> None:
    rc = CMD(
        "az",
        "sql",
        "server",
        "firewall-rule",
        "create",
        "-n",
        rule.name,
        "-s",
        server,
        "-g",
        resource_group,
        "--start-ip-address",
        rule.start_ip,
        "--end-ip-address",
        rule.end_ip,
        config=cfg,
    )
    if rc != 0:
        raise SystemExit(rc)


def _update_rule(
    *,
    rule: ProposedRule,
    server: str,
    resource_group: str,
    cfg: Any,
) -> None:
    rc = CMD(
        "az",
        "sql",
        "server",
        "firewall-rule",
        "update",
        "-n",
        rule.name,
        "-s",
        server,
        "-g",
        resource_group,
        "--start-ip-address",
        rule.start_ip,
        "--end-ip-address",
        rule.end_ip,
        config=cfg,
    )
    if rc != 0:
        raise SystemExit(rc)


def sync_my_ip_rule(
    *,
    server: str,
    resource_group: str,
    by_name: dict[str, tuple[str, str]],
    apply: bool,
) -> None:
    """Upsert a single replaceable {dbxFirstLast}_vpn rule for the caller's public IP."""
    public_ip = detect_public_ipv4()
    name = vpn_rule_name()
    rule = ProposedRule(
        cidr=f"{public_ip}/32",
        name=name,
        start_ip=public_ip,
        end_ip=public_ip,
    )
    existing = by_name.get(name)

    if existing is None:
        action = "create"
    elif existing == (public_ip, public_ip):
        action = "skip"
    else:
        action = "update"

    print(f"VPN my-ip rule: {name} -> {public_ip}/32  ({action})")
    if existing and action == "update":
        print(f"  was {existing[0]}-{existing[1]}")

    if not apply:
        return

    if action == "skip":
        return

    cfg = CmdConfig(exit_on_error="PRINT_EXIT")
    if action == "create":
        _create_rule(rule=rule, server=server, resource_group=resource_group, cfg=cfg)
        print(f"Created VPN rule {name}.")
    else:
        _update_rule(rule=rule, server=server, resource_group=resource_group, cfg=cfg)
        print(f"Updated VPN rule {name}.")


def sync_firewall(
    *,
    server: str,
    resource_group: str,
    existing_rules_path: Path,
    cidrs_raw: str,
    apply: bool,
    my_ip: bool,
) -> None:
    existing = load_existing_rules(existing_rules_path)
    existing_names, existing_ranges, by_name = existing_indexes(existing)
    proposed = build_proposed(split_specs(cidrs_raw)) if cidrs_raw else []

    to_create: list[ProposedRule] = []
    already: list[ProposedRule] = []
    for rule in proposed:
        if rule.name in existing_names or (rule.start_ip, rule.end_ip) in existing_ranges:
            already.append(rule)
        else:
            to_create.append(rule)

    print(f"Target: server={server} resource_group={resource_group}")
    print(
        f"Desired specs: {len(proposed)}  already present: {len(already)}  to create: {len(to_create)}"
    )
    for rule in already:
        print(f"  skip  {rule.name}  {rule.start_ip}-{rule.end_ip}  ({rule.cidr})")
    for rule in to_create:
        print(f"  create {rule.name}  {rule.start_ip}-{rule.end_ip}  ({rule.cidr})")

    if my_ip:
        sync_my_ip_rule(
            server=server,
            resource_group=resource_group,
            by_name=by_name,
            apply=apply,
        )

    if not apply:
        print("--apply not set — skipping firewall-rule mutations.")
        return

    cfg = CmdConfig(exit_on_error="PRINT_EXIT")
    for rule in to_create:
        _create_rule(rule=rule, server=server, resource_group=resource_group, cfg=cfg)

    if to_create:
        print(f"Created {len(to_create)} Azure SQL firewall rule(s) from specs.")
    elif proposed:
        print("No CIDR/range rules to create.")


@app.command()
def main(
    server: Annotated[
        str,
        typer.Option("--server", "-s", help="Azure SQL server name (DB_HOST)."),
    ],
    existing_rules: Annotated[
        Path,
        typer.Option(
            "--existing-rules",
            help="JSON array from: az sql server firewall-rule list",
            exists=True,
            dir_okay=False,
            readable=True,
        ),
    ],
    resource_group: Annotated[
        str | None,
        typer.Option(
            "--resource-group",
            "-g",
            help="Azure resource group. Defaults to az CLI default group.",
        ),
    ] = None,
    cidrs: Annotated[
        str | None,
        typer.Option(
            "--cidrs",
            help="Desired CIDRs and/or start-end ranges (space/comma separated), "
            "e.g. '35.94.1.248/32 0.0.0.1-255.255.255.254'. Defaults to DB_FIREWALL_CIDRS.",
        ),
    ] = None,
    my_ip: Annotated[
        bool,
        typer.Option(
            "--my-ip",
            help="Upsert replaceable {DBX firstname+lastname}_vpn rule with current "
            "public IP (from DBX_USERNAME, e.g. robert.lee@… → robertlee_vpn).",
        ),
    ] = False,
    apply: Annotated[
        bool,
        typer.Option("--apply", help="Create/update Azure SQL firewall rules."),
    ] = False,
) -> None:
    """Diff existing Azure SQL firewall rules vs DB_FIREWALL_CIDRS; optionally apply."""
    cidrs_raw = (cidrs if cidrs is not None else os.environ.get("DB_FIREWALL_CIDRS", "")).strip()
    if not cidrs_raw and not my_ip:
        print("No CIDRs provided (--cidrs or DB_FIREWALL_CIDRS) and --my-ip not set.", file=sys.stderr)
        raise SystemExit(1)

    sync_firewall(
        server=server,
        resource_group=resolve_resource_group(resource_group),
        existing_rules_path=existing_rules,
        cidrs_raw=cidrs_raw,
        apply=apply,
        my_ip=my_ip,
    )


if __name__ == "__main__":
    app()
