#!/usr/bin/env python3
"""Install and configure Databricks Lakeflow Connect SQL Server utility_script.sql.

Owns a version registry (1.4 local, 1.5 docs URL). When --script is omitted,
resolves LATEST_VERSION (1.5) via sqlserver/utility-script-{ver}.sql cache
(download or seed). Dry-run by default; pass --apply to mutate the DB.

Connection contract (env, same as bash SQLCLI/SQLCMD):
  DB_HOST_FQDN, DB_PORT, DB_CATALOG, DB_USERNAME/DBA_USERNAME, DB_PASSWORD/DBA_PASSWORD
"""

from __future__ import annotations

import importlib.util
import os
import re
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Callable, Literal

import typer

# --- load bash_utils/cmd-wrapper-helpers.py (hyphenated filename) ---
_REPO_ROOT = Path(__file__).resolve().parent.parent
_CMD_HELPERS = _REPO_ROOT / "bash_utils" / "cmd-wrapper-helpers.py"
_SQLSERVER_DIR = _REPO_ROOT / "sqlserver"

LATEST_VERSION = "1.5"
SUPPORTED_VERSIONS = ("1.4", "1.5")
CaptureMode = Literal["CT", "CDC", "BOTH"]


@dataclass(frozen=True)
class VersionSpec:
    """Registry entry for one utility_script version."""

    url: str | None
    local: Path | None
    cache: Path
    docs: str | None = None


VERSION_REGISTRY: dict[str, VersionSpec] = {
    "1.4": VersionSpec(
        url=None,
        local=_SQLSERVER_DIR / "utility_script.sql",
        cache=_SQLSERVER_DIR / "utility-script-1.4.sql",
    ),
    "1.5": VersionSpec(
        url=(
            "https://docs.databricks.com/aws/en/assets/files/"
            "utility_script-9a7925923528101cbe1cba8b91d9997a.sql"
        ),
        local=None,
        cache=_SQLSERVER_DIR / "utility-script-1.5.sql",
        docs=(
            "https://docs.databricks.com/aws/en/ingestion/"
            "lakeflow-connect/sql-server-utility-reference"
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

_VERSION_RE = re.compile(r"Version\s+(\d+\.\d+)", re.IGNORECASE)


def detect_script_version(script_path: Path, *, require_supported: bool = True) -> str:
    """Return Version X.Y from the leading comment block of utility_script.sql."""
    if not script_path.is_file() or script_path.stat().st_size == 0:
        raise SystemExit(f"ERROR: missing or empty script: {script_path}")

    # Only scan the leading block comment (first ~4 KiB is enough).
    text = script_path.read_text(encoding="utf-8", errors="replace")[:4096]
    if not text.lstrip().startswith("/*"):
        raise SystemExit(f"ERROR: {script_path} does not start with a /* comment block")

    end = text.find("*/")
    header = text[: end if end != -1 else len(text)]
    match = _VERSION_RE.search(header)
    if not match:
        raise SystemExit(f"ERROR: no 'Version X.Y' found in header of {script_path}")

    version = match.group(1)
    if require_supported and version not in SUPPORTED_VERSIONS:
        raise SystemExit(
            f"ERROR: unsupported utility_script version {version}; "
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


def _seed_cache_from_local(local: Path, cache: Path, expected_version: str) -> None:
    if not local.is_file() or local.stat().st_size == 0:
        raise SystemExit(f"ERROR: missing or empty local source: {local}")
    got = detect_script_version(local)
    if got != expected_version:
        raise SystemExit(
            f"ERROR: local source {local} is version {got}, expected {expected_version}"
        )
    print(f"seeding cache from {local}")
    print(f"  -> {cache}")
    cache.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(local, cache)


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
        _seed_cache_from_local(spec.local, spec.cache, requested)
    else:
        raise SystemExit(
            f"ERROR: no url or local source registered for version {requested}"
        )

    if not _cache_valid(spec.cache, requested):
        raise SystemExit(f"ERROR: failed to materialize cache {spec.cache}")

    print(f"using {spec.cache}")
    return spec.cache.resolve(), requested


def _sql_quote(value: str) -> str:
    """Single-quote a T-SQL string literal (escape embedded quotes)."""
    return "'" + value.replace("'", "''") + "'"


def _version_fn(version: str) -> str:
    """lakeflowUtilityVersion_1_4 for '1.4'."""
    return f"dbo.lakeflowUtilityVersion_{version.replace('.', '_')}()"


def build_setup_sql(
    *,
    version: str,
    user: str,
    tables: str,
    capture_mode: CaptureMode,
    retention: str,
) -> str:
    """Build the post-install EXEC batch for a given version (API currently shared)."""
    del version  # reserved for future per-version SQL drift
    lines: list[str] = ["SET NOCOUNT ON;", "GO"]
    user_q = _sql_quote(user)
    tables_q = _sql_quote(tables)
    retention_q = _sql_quote(retention)

    if capture_mode in ("CT", "BOTH"):
        lines.extend(
            [
                "EXEC dbo.lakeflowSetupChangeTracking",
                f"    @Tables = {tables_q},",
                f"    @User = {user_q},",
                f"    @Retention = {retention_q};",
                "GO",
            ]
        )
    if capture_mode in ("CDC", "BOTH"):
        lines.extend(
            [
                "EXEC dbo.lakeflowSetupChangeDataCapture",
                f"    @Tables = {tables_q},",
                f"    @User = {user_q};",
                "GO",
            ]
        )
    lines.extend(
        [
            "EXEC dbo.lakeflowFixPermissions",
            f"    @User = {user_q},",
            f"    @Tables = {tables_q};",
            "GO",
        ]
    )
    return "\n".join(lines) + "\n"


def build_verify_sql(version: str) -> str:
    return (
        "SET NOCOUNT ON;\n"
        "GO\n"
        f"SELECT {_version_fn(version)} AS UtilityVersion;\n"
        "GO\n"
        "SELECT dbo.lakeflowDetectPlatform() AS Platform;\n"
        "GO\n"
    )


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
    port = (os.environ.get("DB_PORT") or "1433").strip()
    login_timeout = (os.environ.get("DB_LOGIN_TIMEOUT") or "10").strip()

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
        "login_timeout": login_timeout,
    }


def _sqlcmd_cfg() -> object:
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
    """Apply a .sql file via sqlcmd -i (fail loud on non-zero)."""
    if not sql_path.is_file() or sql_path.stat().st_size == 0:
        raise SystemExit(f"ERROR: missing or empty SQL file: {sql_path}")

    conn = _conn_env()
    cfg = _sqlcmd_cfg()
    rc = CMD(
        "sqlcmd",
        "-d",
        conn["catalog"],
        "-S",
        f"{conn['host']},{conn['port']}",
        "-U",
        conn["user"],
        "-P",
        conn["password"],
        "-C",
        "-l",
        conn["login_timeout"],
        "-I",
        "-i",
        str(sql_path),
        config=cfg,
    )
    if rc != 0:
        raise SystemExit(rc)


def run_sql_batch(sql: str, *, label: str) -> None:
    """Write SQL to a temp file and run via sqlcmd -i."""
    if not sql.strip():
        raise SystemExit(f"ERROR: empty SQL batch for {label}")
    with tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".sql",
        prefix=f"lfc_utility_{label}_",
        delete=False,
        encoding="utf-8",
    ) as tmp:
        tmp.write(sql)
        tmp_path = Path(tmp.name)
    try:
        run_sql_file(tmp_path)
    finally:
        tmp_path.unlink(missing_ok=True)


def run_v1_4(
    *,
    script_path: Path,
    user: str,
    tables: str,
    capture_mode: CaptureMode,
    retention: str,
    apply: bool,
    install_only: bool,
    setup_only: bool,
) -> None:
    """Hardcoded path for utility_script Version 1.4."""
    version = "1.4"
    setup_sql = build_setup_sql(
        version=version,
        user=user,
        tables=tables,
        capture_mode=capture_mode,
        retention=retention,
    )
    verify_sql = build_verify_sql(version)

    print(f"utility_script version={version} path={script_path}")
    if not setup_only:
        print(f"plan: install {script_path}")
        print(f"plan: verify {_version_fn(version)}")
    if not install_only:
        print("plan: setup SQL:")
        print(setup_sql)

    if not apply:
        print("--apply not set — skipping SQL mutations.")
        return

    if not setup_only:
        print(f"installing {script_path}")
        run_sql_file(script_path)
        print("verifying install")
        run_sql_batch(verify_sql, label="verify_1_4")

    if not install_only:
        print(f"running setup procs (mode={capture_mode})")
        run_sql_batch(setup_sql, label="setup_1_4")


def run_v1_5(
    *,
    script_path: Path,
    user: str,
    tables: str,
    capture_mode: CaptureMode,
    retention: str,
    apply: bool,
    install_only: bool,
    setup_only: bool,
) -> None:
    """Hardcoded path for utility_script Version 1.5."""
    version = "1.5"
    setup_sql = build_setup_sql(
        version=version,
        user=user,
        tables=tables,
        capture_mode=capture_mode,
        retention=retention,
    )
    verify_sql = build_verify_sql(version)

    print(f"utility_script version={version} path={script_path}")
    if not setup_only:
        print(f"plan: install {script_path}")
        print(f"plan: verify {_version_fn(version)}")
    if not install_only:
        print("plan: setup SQL:")
        print(setup_sql)

    if not apply:
        print("--apply not set — skipping SQL mutations.")
        return

    if not setup_only:
        print(f"installing {script_path}")
        run_sql_file(script_path)
        print("verifying install")
        run_sql_batch(verify_sql, label="verify_1_5")

    if not install_only:
        print(f"running setup procs (mode={capture_mode})")
        run_sql_batch(setup_sql, label="setup_1_5")


HANDLERS: dict[str, Callable[..., None]] = {
    "1.4": run_v1_4,
    "1.5": run_v1_5,
}


@app.command()
def main(
    script: Annotated[
        Path | None,
        typer.Option(
            "--script",
            help="Path to a utility_script.sql file. "
            "If omitted, resolve LATEST_VERSION (or --version) via cache.",
            exists=False,
            dir_okay=False,
        ),
    ] = None,
    version: Annotated[
        str | None,
        typer.Option(
            "--version",
            help=f"Registered version to resolve when --script is omitted "
            f"(default: {LATEST_VERSION}). Registered: "
            f"{', '.join(VERSION_REGISTRY)}.",
        ),
    ] = None,
    user: Annotated[
        str | None,
        typer.Option("--user", help="Ingestion DB user. Defaults to USER_USERNAME."),
    ] = None,
    tables: Annotated[
        str | None,
        typer.Option(
            "--tables",
            help="lakeflow @Tables value (e.g. SCHEMAS:demo, ALL). "
            "Defaults to SCHEMAS:${DB_SCHEMA} or ALL.",
        ),
    ] = None,
    capture_mode: Annotated[
        str | None,
        typer.Option(
            "--capture-mode",
            help="CT | CDC | BOTH. Defaults to CDC_CT_MODE.",
        ),
    ] = None,
    retention: Annotated[
        str,
        typer.Option("--retention", help="CT retention (SetupChangeTracking only)."),
    ] = "2 DAYS",
    apply: Annotated[
        bool,
        typer.Option("--apply", help="Install/setup against the database."),
    ] = False,
    install_only: Annotated[
        bool,
        typer.Option("--install-only", help="Only install utility objects (+ verify)."),
    ] = False,
    setup_only: Annotated[
        bool,
        typer.Option("--setup-only", help="Only run Setup*/FixPermissions procs."),
    ] = False,
) -> None:
    """Detect utility_script version and run the matching install/setup path."""
    if install_only and setup_only:
        print("ERROR: --install-only and --setup-only are mutually exclusive", file=sys.stderr)
        raise SystemExit(1)

    if version is not None and version not in VERSION_REGISTRY:
        print(
            f"ERROR: --version {version} not registered; "
            f"known: {', '.join(VERSION_REGISTRY)}",
            file=sys.stderr,
        )
        raise SystemExit(1)

    script_path, resolved_version = resolve_script(script=script, version=version)

    resolved_user = (user or os.environ.get("USER_USERNAME") or "").strip()
    if not resolved_user:
        if apply and not install_only:
            print("ERROR: --user or USER_USERNAME required for setup", file=sys.stderr)
            raise SystemExit(1)
        resolved_user = "<USER_USERNAME>"

    schema = (os.environ.get("DB_SCHEMA") or "").strip()
    if tables is not None:
        resolved_tables = tables.strip()
    elif schema:
        resolved_tables = f"SCHEMAS:{schema}"
    else:
        resolved_tables = "ALL"

    mode_raw = (capture_mode or os.environ.get("CDC_CT_MODE") or "BOTH").strip().upper()
    if mode_raw not in ("CT", "CDC", "BOTH"):
        print(
            f"ERROR: --capture-mode / CDC_CT_MODE must be CT, CDC, or BOTH (got {mode_raw})",
            file=sys.stderr,
        )
        raise SystemExit(1)
    mode: CaptureMode = mode_raw  # type: ignore[assignment]

    handler = HANDLERS[resolved_version]
    handler(
        script_path=script_path,
        user=resolved_user,
        tables=resolved_tables,
        capture_mode=mode,
        retention=retention,
        apply=apply,
        install_only=install_only,
        setup_only=setup_only,
    )


if __name__ == "__main__":
    app()
