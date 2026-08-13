#!/usr/bin/env python3
"""Install Databricks Lakeflow Connect MySQL utility objects script.

Owns a version registry (1.0 docs URL). When --script is omitted, resolves
LATEST_VERSION (1.0) via mysql/lakeflow_mysql_utility_script-{ver}.sql
cache (download). Dry-run by default; pass --apply to mutate the DB.

Docs:
  https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/mysql-utility-script

Connection contract (env, same as bash SQLCLI/MYSQLCLI):
  DB_HOST_FQDN, DB_PORT, DB_CATALOG, DB_USERNAME/DBA_USERNAME, DB_PASSWORD/DBA_PASSWORD

Does not call lakeflow_cdc_setup (managed Azure/RDS/GCP configure binlog via
server parameters). Use --user/--tables with --apply to CALL lakeflow_setup_cdc_user.
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
_MYSQL_DIR = _REPO_ROOT / "mysql"

LATEST_VERSION = "1.0"
SUPPORTED_VERSIONS = ("1.0",)


@dataclass(frozen=True)
class VersionSpec:
    """Registry entry for one MySQL utility script version."""

    url: str | None
    local: Path | None
    cache: Path
    docs: str | None = None


VERSION_REGISTRY: dict[str, VersionSpec] = {
    "1.0": VersionSpec(
        url=(
            "https://docs.databricks.com/aws/en/assets/files/"
            "mysql_utility_script-3e486cd9536d292caa4a84df2acd6bb0.sql"
        ),
        local=None,
        cache=_MYSQL_DIR / "lakeflow_mysql_utility_script-1.0.sql",
        docs=(
            "https://docs.databricks.com/aws/en/ingestion/"
            "lakeflow-connect/mysql-utility-script"
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

# Upstream asset has no Version X.Y; fingerprint + procedure names identify 1.0.
_FINGERPRINT_RE = re.compile(
    r"MySQL\s+Change\s+Data\s+Capture\s+\(CDC\)\s+User\s+Setup\s+Script",
    re.IGNORECASE,
)
_PROC_SETUP_USER = "lakeflow_setup_cdc_user"
_PROC_CDC_SETUP = "lakeflow_cdc_setup"


def detect_script_version(script_path: Path, *, require_supported: bool = True) -> str:
    """Return registry version for a fingerprint-validated utility script."""
    if not script_path.is_file() or script_path.stat().st_size == 0:
        raise SystemExit(f"ERROR: missing or empty script: {script_path}")

    text = script_path.read_text(encoding="utf-8", errors="replace")
    header = text[:8192]
    if not _FINGERPRINT_RE.search(header):
        raise SystemExit(
            f"ERROR: no 'MySQL Change Data Capture (CDC) User Setup Script' "
            f"fingerprint in header of {script_path}"
        )
    if _PROC_SETUP_USER not in text or _PROC_CDC_SETUP not in text:
        raise SystemExit(
            f"ERROR: missing {_PROC_SETUP_USER} and/or {_PROC_CDC_SETUP} in {script_path}"
        )

    # This asset maps to registry 1.0 (no Version X.Y in upstream header).
    version = "1.0"
    if require_supported and version not in SUPPORTED_VERSIONS:
        raise SystemExit(
            f"ERROR: unsupported MySQL utility script version {version}; "
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
                f"ERROR: --version {version} does not match script "
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
    port = (os.environ.get("DB_PORT") or "3306").strip()

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


def _mysql_cfg() -> object:
    secrets = [
        os.environ.get("DBA_PASSWORD", ""),
        os.environ.get("USER_PASSWORD", ""),
        os.environ.get("DB_PASSWORD", ""),
    ]
    return CmdConfig(
        exit_on_error="PRINT_EXIT",
        mask_secrets=[s for s in secrets if s],
    )


def _mysql_base_args(conn: dict[str, str]) -> list[str]:
    return [
        "mysql",
        "--user",
        conn["user"],
        "--host",
        conn["host"],
        "--port",
        conn["port"],
        "--database",
        conn["catalog"],
    ]


def run_sql_file(sql_path: Path) -> None:
    """Apply a .sql file via mysql -e 'source …' so DELIMITER works."""
    if not sql_path.is_file() or sql_path.stat().st_size == 0:
        raise SystemExit(f"ERROR: missing or empty SQL file: {sql_path}")

    conn = _conn_env()
    cfg = _mysql_cfg()
    abs_path = sql_path.resolve()
    # source path: escape backslashes for Windows-ish paths; keep spaces quoted via -e.
    source_stmt = f"source {abs_path}"
    prev_pw = os.environ.get("MYSQL_PWD")
    os.environ["MYSQL_PWD"] = conn["password"]
    try:
        rc = CMD(
            *_mysql_base_args(conn),
            "-e",
            source_stmt,
            config=cfg,
        )
    finally:
        if prev_pw is None:
            os.environ.pop("MYSQL_PWD", None)
        else:
            os.environ["MYSQL_PWD"] = prev_pw
    if rc != 0:
        raise SystemExit(rc)


def _sql_quote_literal(value: str) -> str:
    """Escape a value for use inside a single-quoted MySQL string literal."""
    return value.replace("\\", "\\\\").replace("'", "''")


def call_setup_cdc_user(username: str, tables: str) -> None:
    """CALL lakeflow_setup_cdc_user(user, tables) — no lakeflow_cdc_setup."""
    user = username.strip()
    tables_list = tables.strip()
    if not user:
        raise SystemExit("ERROR: --user is required for lakeflow_setup_cdc_user")
    if not tables_list:
        raise SystemExit("ERROR: --tables is required for lakeflow_setup_cdc_user")

    conn = _conn_env()
    cfg = _mysql_cfg()
    sql = (
        f"CALL {_PROC_SETUP_USER}("
        f"'{_sql_quote_literal(user)}', "
        f"'{_sql_quote_literal(tables_list)}')"
    )
    print(f"calling {_PROC_SETUP_USER}(user={user!r}, tables={tables_list!r})")
    prev_pw = os.environ.get("MYSQL_PWD")
    os.environ["MYSQL_PWD"] = conn["password"]
    try:
        rc = CMD(
            *_mysql_base_args(conn),
            "-e",
            sql,
            config=cfg,
        )
    finally:
        if prev_pw is None:
            os.environ.pop("MYSQL_PWD", None)
        else:
            os.environ["MYSQL_PWD"] = prev_pw
    if rc != 0:
        raise SystemExit(rc)


@app.command()
def main(
    script: Annotated[
        Path | None,
        typer.Option("--script", help="Path to MySQL utility .sql (skips registry)."),
    ] = None,
    version: Annotated[
        str | None,
        typer.Option("--version", help=f"Registry version (default {LATEST_VERSION})."),
    ] = None,
    apply: Annotated[
        bool,
        typer.Option("--apply", help="Apply the script to the database via mysql."),
    ] = False,
    user: Annotated[
        str | None,
        typer.Option(
            "--user",
            help="CDC username for CALL lakeflow_setup_cdc_user (requires --apply).",
        ),
    ] = None,
    tables: Annotated[
        str | None,
        typer.Option(
            "--tables",
            help=(
                "Table list for CALL lakeflow_setup_cdc_user, e.g. "
                "`mydb`.* (requires --apply and --user)."
            ),
        ),
    ] = None,
) -> None:
    """Resolve/download Lakeflow MySQL utility script; optionally apply + setup user."""
    script_path, resolved_version = resolve_script(script=script, version=version)
    print(f"resolved version={resolved_version} path={script_path}")

    if (user is None) != (tables is None):
        raise SystemExit("ERROR: --user and --tables must be passed together")

    if not apply:
        if user is not None:
            raise SystemExit("ERROR: --user/--tables require --apply")
        print("--apply not set — dry-run only (no DB mutation).")
        return

    print(f"applying {script_path} to {os.environ.get('DB_CATALOG', '')}")
    run_sql_file(script_path)
    print("MySQL utility objects script applied.")

    if user is not None and tables is not None:
        call_setup_cdc_user(user, tables)
        print(f"{_PROC_SETUP_USER} completed.")


if __name__ == "__main__":
    app()
