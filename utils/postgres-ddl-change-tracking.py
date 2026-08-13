#!/usr/bin/env python3
"""Install Databricks Lakeflow Connect PostgreSQL DDL change-tracking script.

Owns a version registry (1.0 docs URL). When --script is omitted, resolves
LATEST_VERSION (1.0) via postgres/lakeflow_pg_ddl_change_tracking-{ver}.sql
cache (download). Dry-run by default; pass --apply to mutate the DB.

Docs:
  https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/postgresql-source-setup#optional-configure-inline-ddl-tracking

Connection contract (env, same as bash SQLCLI/PSQL):
  DB_HOST_FQDN, DB_PORT, DB_CATALOG, DB_USERNAME/DBA_USERNAME, DB_PASSWORD/DBA_PASSWORD
"""

from __future__ import annotations

import importlib.util
import os
import re
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated

import typer

# --- load bash_utils/cmd-wrapper-helpers.py (hyphenated filename) ---
_REPO_ROOT = Path(__file__).resolve().parent.parent
_CMD_HELPERS = _REPO_ROOT / "bash_utils" / "cmd-wrapper-helpers.py"
_POSTGRES_DIR = _REPO_ROOT / "postgres"

LATEST_VERSION = "1.0"
SUPPORTED_VERSIONS = ("1.0",)


@dataclass(frozen=True)
class VersionSpec:
    """Registry entry for one DDL change-tracking script version."""

    url: str | None
    local: Path | None
    cache: Path
    docs: str | None = None


VERSION_REGISTRY: dict[str, VersionSpec] = {
    "1.0": VersionSpec(
        url=(
            "https://docs.databricks.com/aws/en/assets/files/"
            "lakeflow_pg_ddl_change_tracking-405aa758bf4c636937ffe0ba58151d98.sql"
        ),
        local=None,
        cache=_POSTGRES_DIR / "lakeflow_pg_ddl_change_tracking-1.0.sql",
        docs=(
            "https://docs.databricks.com/aws/en/ingestion/"
            "lakeflow-connect/postgresql-source-setup"
            "#optional-configure-inline-ddl-tracking"
        ),
    ),
}


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

# Header: "-- Lakeflow DDL Audit Setup Script v1.0"
_VERSION_RE = re.compile(
    r"Lakeflow\s+DDL\s+Audit\s+Setup\s+Script\s+v(\d+\.\d+)",
    re.IGNORECASE,
)


def detect_script_version(script_path: Path, *, require_supported: bool = True) -> str:
    """Return version X.Y from the leading comment header."""
    if not script_path.is_file() or script_path.stat().st_size == 0:
        raise SystemExit(f"ERROR: missing or empty script: {script_path}")

    text = script_path.read_text(encoding="utf-8", errors="replace")[:8192]
    match = _VERSION_RE.search(text)
    if not match:
        raise SystemExit(
            f"ERROR: no 'Lakeflow DDL Audit Setup Script vX.Y' found in header of {script_path}"
        )

    version = match.group(1)
    if require_supported and version not in SUPPORTED_VERSIONS:
        raise SystemExit(
            f"ERROR: unsupported DDL script version {version}; "
            f"supported: {', '.join(SUPPORTED_VERSIONS)}"
        )
    return version


def _cache_valid(cache: Path, expected_version: str) -> bool:
    if not cache.is_file() or cache.stat().st_size == 0:
        return False
    try:
        return detect_script_version(cache) == expected_version
    except SystemExit:
        return False


def _atomic_write(dest: Path, data: bytes) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{dest.name}.",
        suffix=".tmp",
        dir=str(dest.parent),
    )
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as tmp:
            tmp.write(data)
            tmp.flush()
            os.fsync(tmp.fileno())
        tmp_path.replace(dest)
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


def _download_to_cache(url: str, cache: Path, expected_version: str) -> None:
    print(f"downloading {url}")
    print(f"  -> {cache}")
    try:
        with urllib.request.urlopen(url, timeout=60) as resp:
            status = getattr(resp, "status", None) or resp.getcode()
            if status != 200:
                raise SystemExit(f"ERROR: download HTTP {status} for {url}")
            data = resp.read()
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"ERROR: download HTTP {exc.code} for {url}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"ERROR: download failed for {url}: {exc.reason}") from exc

    if not data or not data.strip():
        raise SystemExit(f"ERROR: empty download from {url}")

    _atomic_write(cache, data)
    got = detect_script_version(cache)
    if got != expected_version:
        cache.unlink(missing_ok=True)
        raise SystemExit(
            f"ERROR: downloaded script version {got} != expected {expected_version}"
        )


def resolve_script(
    *,
    script: Path | None,
    version: str | None,
) -> tuple[Path, str]:
    """Resolve (script_path, version) from --script / --version / LATEST_VERSION."""
    if script is not None:
        script_path = script.expanduser().resolve()
        detected = detect_script_version(script_path)
        if version is not None and version != detected:
            raise SystemExit(
                f"ERROR: --version {version} does not match script header "
                f"version {detected} at {script_path}"
            )
        return script_path, detected

    requested = (version or LATEST_VERSION).strip()
    if requested not in VERSION_REGISTRY:
        raise SystemExit(
            f"ERROR: unknown version {requested}; "
            f"registered: {', '.join(VERSION_REGISTRY)}"
        )

    spec = VERSION_REGISTRY[requested]
    if _cache_valid(spec.cache, requested):
        print(f"using cached {spec.cache}")
        return spec.cache.resolve(), requested

    if spec.url:
        _download_to_cache(spec.url, spec.cache, requested)
    elif spec.local is not None:
        if not spec.local.is_file() or spec.local.stat().st_size == 0:
            raise SystemExit(f"ERROR: missing or empty local source: {spec.local}")
        print(f"seeding cache from {spec.local}")
        print(f"  -> {spec.cache}")
        spec.cache.parent.mkdir(parents=True, exist_ok=True)
        spec.cache.write_bytes(spec.local.read_bytes())
    else:
        raise SystemExit(
            f"ERROR: no url or local source registered for version {requested}"
        )

    if not _cache_valid(spec.cache, requested):
        raise SystemExit(f"ERROR: failed to materialize cache {spec.cache}")

    print(f"using {spec.cache}")
    return spec.cache.resolve(), requested


def _conn_env() -> dict[str, str]:
    host = os.environ.get("DB_HOST_FQDN", "").strip()
    catalog = os.environ.get("DB_CATALOG", "").strip()
    user = (
        os.environ.get("DB_USERNAME")
        or os.environ.get("DBA_USERNAME")
        or ""
    ).strip()
    password = (
        os.environ.get("DB_PASSWORD")
        or os.environ.get("DBA_PASSWORD")
        or ""
    ).strip()
    port = (os.environ.get("DB_PORT") or "5432").strip()

    missing = [
        name
        for name, val in (
            ("DB_HOST_FQDN", host),
            ("DB_CATALOG", catalog),
            ("DB_USERNAME/DBA_USERNAME", user),
            ("DB_PASSWORD/DBA_PASSWORD", password),
        )
        if not val
    ]
    if missing:
        raise SystemExit(f"ERROR: missing connection env: {', '.join(missing)}")

    return {
        "host": host,
        "port": port,
        "catalog": catalog,
        "user": user,
        "password": password,
    }


def _psql_cfg() -> object:
    secrets = [
        os.environ.get("DBA_PASSWORD", ""),
        os.environ.get("USER_PASSWORD", ""),
        os.environ.get("DB_PASSWORD", ""),
    ]
    return CmdConfig(
        exit_on_error="PRINT_EXIT",
        mask_secrets=[s for s in secrets if s],
    )


def run_sql_file(sql_path: Path) -> None:
    """Apply a .sql file via psql -f (fail loud on non-zero)."""
    if not sql_path.is_file() or sql_path.stat().st_size == 0:
        raise SystemExit(f"ERROR: missing or empty SQL file: {sql_path}")

    conn = _conn_env()
    cfg = _psql_cfg()
    prev_pw = os.environ.get("PGPASSWORD")
    os.environ["PGPASSWORD"] = conn["password"]
    try:
        rc = CMD(
            "psql",
            "-h",
            conn["host"],
            "-p",
            conn["port"],
            "-U",
            conn["user"],
            "-d",
            conn["catalog"],
            "-v",
            "ON_ERROR_STOP=1",
            "-f",
            str(sql_path),
            config=cfg,
        )
    finally:
        if prev_pw is None:
            os.environ.pop("PGPASSWORD", None)
        else:
            os.environ["PGPASSWORD"] = prev_pw
    if rc != 0:
        raise SystemExit(rc)


def audit_table_name(version: str) -> str:
    """public.lakeflow_ddl_audit_table_1_0 for version 1.0."""
    return f"lakeflow_ddl_audit_table_{version.replace('.', '_')}"


@app.command()
def main(
    script: Annotated[
        Path | None,
        typer.Option("--script", help="Path to DDL change-tracking .sql (skips registry)."),
    ] = None,
    version: Annotated[
        str | None,
        typer.Option("--version", help=f"Registry version (default {LATEST_VERSION})."),
    ] = None,
    apply: Annotated[
        bool,
        typer.Option("--apply", help="Apply the script to the database via psql."),
    ] = False,
) -> None:
    """Resolve/download Lakeflow PG DDL change-tracking script; optionally apply."""
    script_path, resolved_version = resolve_script(script=script, version=version)
    print(f"resolved version={resolved_version} path={script_path}")
    print(f"audit table will be public.{audit_table_name(resolved_version)}")

    if not apply:
        print("--apply not set — dry-run only (no DB mutation).")
        return

    print(f"applying {script_path} to {os.environ.get('DB_CATALOG', '')}")
    run_sql_file(script_path)
    print("DDL change-tracking script applied.")


if __name__ == "__main__":
    app()
