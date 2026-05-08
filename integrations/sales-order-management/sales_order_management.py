#!/usr/bin/env python3
"""
Sales Order Management → Veza OAA Integration

Collects identity and group membership data from the Sales Order Management
Oracle database and pushes it to Veza via the Open Authorization API (OAA).

Entity model:
  Local User  ← SOM_USER   (SOM_USER_ID, SOM_USER_NAME, SOM_USER_ACTIVE_FLAG)
  Local Group ← SOM_GROUP  (SOM_GROUP_ID, SOM_GROUP_DESC)
  Membership  ← SOM_USER_GROUP join (user belongs to group)
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler

from dotenv import load_dotenv
from oaaclient.client import OAAClient, OAAClientError
from oaaclient.templates import CustomApplication, OAAPermission

try:
    import oracledb
except ImportError:
    print("ERROR: oracledb package not installed. Run: pip install oracledb")
    sys.exit(1)

log = logging.getLogger(__name__)

# ── SQL Queries ───────────────────────────────────────────────────────────────

# Fetches all users along with every group they belong to (one row per membership).
# Users not assigned to any group are excluded by the inner join.
ACCOUNT_QUERY = """
SELECT
    su.SOM_USER_ID,
    su.SOM_USER_NAME,
    su.SOM_USER_ACTIVE_FLAG,
    sg.SOM_GROUP_DESC,
    su.TIMESTAMP,
    su.USERSTAMP
FROM
    som_user       su,
    som_user_group sug,
    som_group      sg
WHERE
    su.SOM_USER_ID   = sug.SOM_USER_ID
AND sug.SOM_GROUP_ID = sg.SOM_GROUP_ID
"""

# Fetches all group definitions, including empty groups.
GROUP_QUERY = """
SELECT SOM_GROUP_ID, SOM_GROUP_DESC FROM som_group
"""


# ── Logging ───────────────────────────────────────────────────────────────────

def _setup_logging(log_level: str = "INFO") -> None:
    """Configure file-only logging with hourly rotation to the logs/ folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    log_dir = os.path.join(script_dir, "logs")
    os.makedirs(log_dir, exist_ok=True)

    timestamp = datetime.now().strftime("%d%m%Y-%H%M")
    script_name = os.path.splitext(os.path.basename(__file__))[0]
    log_file = os.path.join(log_dir, f"{script_name}_{timestamp}.log")

    handler = TimedRotatingFileHandler(
        log_file,
        when="h",
        interval=1,
        backupCount=24,
        encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter(
        fmt="%(asctime)s %(levelname)-8s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    ))

    root = logging.getLogger()
    root.setLevel(getattr(logging, log_level.upper(), logging.INFO))
    root.addHandler(handler)


# ── Config ────────────────────────────────────────────────────────────────────

def parse_jdbc_url(jdbc_url: str) -> str:
    """Convert a JDBC Oracle URL to an oracledb EZConnect DSN string.

    Supported input formats:
      jdbc:oracle:thin:@hostname:port:SID          → hostname:port/SID
      jdbc:oracle:thin:@//hostname:port/service     → hostname:port/service
      hostname:port/service                         → passed through unchanged
    """
    if not jdbc_url:
        return jdbc_url

    # Strip JDBC prefix: jdbc:oracle:thin:@ (or jdbc:oracle:oci:@ etc.)
    cleaned = re.sub(r"^jdbc:oracle:[^:]+:@", "", jdbc_url, flags=re.IGNORECASE)
    # Drop leading // (EZConnect style)
    cleaned = re.sub(r"^//", "", cleaned)
    # Convert SID format  hostname:port:SID  →  hostname:port/SID
    sid_match = re.match(r"^([^:/]+):(\d+):([^/]+)$", cleaned)
    if sid_match:
        host, port, sid = sid_match.groups()
        cleaned = f"{host}:{port}/{sid}"

    return cleaned


def _parse_extra_params(raw: str) -> dict:
    """Parse DB_EXTRA_PARAMS as a JSON object; return empty dict on failure."""
    if not raw:
        return {}
    try:
        result = json.loads(raw)
        if isinstance(result, dict):
            return result
    except (json.JSONDecodeError, ValueError):
        log.warning("DB_EXTRA_PARAMS could not be parsed as JSON — ignoring. "
                    "Expected format: '{\"tcp_connect_timeout\": 5}'")
    return {}


def load_config(args: argparse.Namespace) -> dict:
    """Resolve configuration from CLI args → env vars → .env file."""
    if args.env_file and os.path.exists(args.env_file):
        load_dotenv(args.env_file)
    elif args.env_file and args.env_file != ".env":
        log.warning("Specified --env-file '%s' not found", args.env_file)

    config = {
        "veza_url":        args.veza_url        or os.getenv("VEZA_URL"),
        "veza_api_key":    args.veza_api_key    or os.getenv("VEZA_API_KEY"),
        "db_url":          args.db_url          or os.getenv("DB_URL"),
        "db_username":     args.db_username     or os.getenv("DB_USERNAME"),
        "db_password":     args.db_password     or os.getenv("DB_PASSWORD"),
        "db_driver_class": args.db_driver       or os.getenv("DB_DRIVER_CLASS", "oracle.jdbc.OracleDriver"),
        "db_extra_params": args.db_extra        or os.getenv("DB_EXTRA_PARAMS", ""),
        "provider_name":   args.provider_name   or os.getenv("PROVIDER_NAME", "Sales Order Management"),
        "datasource_name": args.datasource_name or os.getenv("DATASOURCE_NAME", "SOM"),
    }

    missing_db = [k for k in ("db_url", "db_username", "db_password") if not config[k]]
    if missing_db:
        log.error("Missing required database configuration: %s", ", ".join(missing_db))
        sys.exit(1)

    if not args.dry_run:
        missing_veza = [k for k in ("veza_url", "veza_api_key") if not config[k]]
        if missing_veza:
            log.error(
                "Missing Veza configuration (required unless --dry-run): %s",
                ", ".join(missing_veza),
            )
            sys.exit(1)

    return config


# ── Database ──────────────────────────────────────────────────────────────────

def get_db_connection(config: dict) -> "oracledb.Connection":
    """Open a thin-mode Oracle connection using oracledb."""
    dsn = parse_jdbc_url(config["db_url"])
    extra_kwargs = _parse_extra_params(config["db_extra_params"])

    log.info("Connecting to Oracle — dsn=%s user=%s", dsn, config["db_username"])
    log.debug("Driver class (informational): %s", config["db_driver_class"])

    try:
        conn = oracledb.connect(
            user=config["db_username"],
            password=config["db_password"],
            dsn=dsn,
            **extra_kwargs,
        )
        log.info("Oracle connection established (thin mode)")
        return conn
    except oracledb.DatabaseError as exc:
        log.error("Oracle connection failed: %s", exc)
        sys.exit(1)


def fetch_groups(cursor: "oracledb.Cursor") -> list:
    """Return all SOM groups as a list of dicts."""
    log.debug("Executing GROUP_QUERY")
    cursor.execute(GROUP_QUERY)
    columns = [col[0].upper() for col in cursor.description]
    rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
    log.info("Fetched %d groups", len(rows))
    return rows


def fetch_memberships(cursor: "oracledb.Cursor") -> list:
    """Return all user-group membership rows as a list of dicts."""
    log.debug("Executing ACCOUNT_QUERY")
    cursor.execute(ACCOUNT_QUERY)
    columns = [col[0].upper() for col in cursor.description]
    rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
    log.info("Fetched %d user-group membership rows", len(rows))
    return rows


# ── OAA Payload ───────────────────────────────────────────────────────────────

def build_oaa_payload(
    groups: list,
    memberships: list,
    provider_name: str,
    datasource_name: str,
) -> CustomApplication:
    """Assemble the OAA CustomApplication payload from Oracle data."""
    app = CustomApplication(name=datasource_name, application_type=provider_name)

    # Single permission: being a member of a group implies DataRead access.
    app.add_custom_permission("member", [OAAPermission.DataRead])

    # ── Groups ────────────────────────────────────────────────────────────────
    for row in groups:
        group_name = row.get("SOM_GROUP_DESC") or row.get("SOM_GROUP_ID")
        if not group_name:
            log.warning("Skipping group row with no name/description: %s", row)
            continue
        app.add_local_group(str(group_name))
        log.debug("Added group: %s", group_name)

    log.info("Added %d groups to OAA payload", len(groups))

    # ── Users and memberships ─────────────────────────────────────────────────
    # Membership rows are one-per-user-group pair; aggregate by user ID.
    users_seen: dict = {}
    user_groups: dict = {}

    for row in memberships:
        user_id = row.get("SOM_USER_ID")
        if not user_id:
            log.debug("Skipping membership row with no SOM_USER_ID: %s", row)
            continue

        user_id_str = str(user_id)
        if user_id_str not in users_seen:
            users_seen[user_id_str] = row
            user_groups[user_id_str] = set()

        group_desc = row.get("SOM_GROUP_DESC")
        if group_desc:
            user_groups[user_id_str].add(str(group_desc))

    log.info("Found %d unique users across membership rows", len(users_seen))

    for user_id, row in users_seen.items():
        user_name = row.get("SOM_USER_NAME") or user_id
        active_raw = str(row.get("SOM_USER_ACTIVE_FLAG", "Y")).strip().upper()
        is_active = active_raw in ("Y", "1", "TRUE", "YES", "ACTIVE")

        local_user = app.add_local_user(
            name=str(user_name),
            unique_id=user_id,
        )
        local_user.is_active = is_active

        for group_name in user_groups.get(user_id, set()):
            try:
                local_user.add_group(group_name)
                log.debug("Assigned user %s → group %s", user_id, group_name)
            except Exception as exc:  # noqa: BLE001
                log.warning(
                    "Could not assign user %s to group %s: %s",
                    user_id, group_name, exc,
                )

    return app


# ── Veza Push ─────────────────────────────────────────────────────────────────

def push_to_veza(
    veza_url: str,
    veza_api_key: str,
    provider_name: str,
    datasource_name: str,
    app: CustomApplication,
    dry_run: bool = False,
    save_json: str | None = None,
) -> None:
    """Push the OAA payload to Veza; optionally save the JSON for inspection."""
    if save_json:
        with open(save_json, "w", encoding="utf-8") as fh:
            json.dump(app.get_payload(), fh, indent=2, default=str)
        log.info("Payload saved to %s", save_json)
        print(f"Payload saved → {save_json}")

    if dry_run:
        log.info("[DRY RUN] Payload built successfully — Veza push skipped")
        print("[DRY RUN] Payload built successfully. Veza push skipped.")
        return

    veza_con = OAAClient(url=veza_url, token=veza_api_key)
    try:
        response = veza_con.push_application(
            provider_name=provider_name,
            data_source_name=datasource_name,
            application_object=app,
            create_provider=True,
        )
        if response and response.get("warnings"):
            for warning in response["warnings"]:
                log.warning("Veza warning: %s", warning)
        log.info("Successfully pushed to Veza")
        print("Successfully pushed to Veza.")
    except OAAClientError as exc:
        log.error(
            "Veza push failed: %s — %s (HTTP %s)",
            exc.error, exc.message, exc.status_code,
        )
        if hasattr(exc, "details"):
            for detail in exc.details:
                log.error("  Detail: %s", detail)
        sys.exit(1)


# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sales Order Management → Veza OAA Integration",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    veza_grp = parser.add_argument_group("Veza Configuration")
    veza_grp.add_argument(
        "--veza-url", default=None,
        help="Veza tenant URL, e.g. https://company.veza.com  (env: VEZA_URL)",
    )
    veza_grp.add_argument(
        "--veza-api-key", default=None,
        help="Veza API key (env: VEZA_API_KEY)",
    )
    veza_grp.add_argument(
        "--provider-name", default=None,
        help="Provider name shown in Veza UI (env: PROVIDER_NAME, default: Sales Order Management)",
    )
    veza_grp.add_argument(
        "--datasource-name", default=None,
        help="Datasource name shown in Veza UI (env: DATASOURCE_NAME, default: SOM)",
    )

    db_grp = parser.add_argument_group("Database Configuration")
    db_grp.add_argument(
        "--db-url", default=None,
        help=(
            "Oracle DB connection URL. Accepts JDBC format "
            "(jdbc:oracle:thin:@host:port/svc) or EZConnect (host:port/svc). "
            "(env: DB_URL)"
        ),
    )
    db_grp.add_argument(
        "--db-username", default=None,
        help="DB username (env: DB_USERNAME)",
    )
    db_grp.add_argument(
        "--db-password", default=None,
        help="DB password (env: DB_PASSWORD)",
    )
    db_grp.add_argument(
        "--db-driver", default=None,
        help="JDBC driver class — informational only, not used by oracledb (env: DB_DRIVER_CLASS)",
    )
    db_grp.add_argument(
        "--db-extra", default=None,
        help=(
            "Additional oracledb connection parameters as a JSON object, "
            'e.g. \'{"tcp_connect_timeout": 5}\' (env: DB_EXTRA_PARAMS)'
        ),
    )

    rt_grp = parser.add_argument_group("Runtime Options")
    rt_grp.add_argument(
        "--env-file", default=".env",
        help="Path to .env credentials file",
    )
    rt_grp.add_argument(
        "--dry-run", action="store_true",
        help="Build OAA payload locally without pushing to Veza",
    )
    rt_grp.add_argument(
        "--save-json", default=None, metavar="PATH",
        help="Save the OAA payload as JSON to PATH for inspection",
    )
    rt_grp.add_argument(
        "--log-level", default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging verbosity",
    )

    return parser.parse_args()


# ── Entry Point ───────────────────────────────────────────────────────────────

def main() -> None:
    args = parse_args()
    _setup_logging(args.log_level)

    print("=" * 62)
    print("  Sales Order Management → Veza OAA Integration")
    print(f"  Mode: {'DRY RUN (no Veza push)' if args.dry_run else 'LIVE PUSH'}")
    print("=" * 62)

    config = load_config(args)
    log.info("Starting SOM OAA integration — dry_run=%s provider=%s datasource=%s",
             args.dry_run, config["provider_name"], config["datasource_name"])

    conn = get_db_connection(config)
    try:
        cursor = conn.cursor()
        try:
            groups = fetch_groups(cursor)
            memberships = fetch_memberships(cursor)
        finally:
            cursor.close()
    finally:
        conn.close()
        log.debug("Oracle connection closed")

    app = build_oaa_payload(
        groups=groups,
        memberships=memberships,
        provider_name=config["provider_name"],
        datasource_name=config["datasource_name"],
    )

    # Default JSON output path for dry-run convenience
    save_json_path = args.save_json
    if args.dry_run and not save_json_path:
        save_json_path = "som_oaa_payload.json"

    push_to_veza(
        veza_url=config["veza_url"],
        veza_api_key=config["veza_api_key"],
        provider_name=config["provider_name"],
        datasource_name=config["datasource_name"],
        app=app,
        dry_run=args.dry_run,
        save_json=save_json_path,
    )

    log.info("Integration complete")
    print("Done.")


if __name__ == "__main__":
    main()
