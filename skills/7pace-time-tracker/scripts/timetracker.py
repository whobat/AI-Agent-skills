#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
7pace Time Tracker - REST API client

Called directly by LLM agents to:
  - Create time entries (single day or batch over a date range)
  - Update existing worklogs
  - Delete worklogs
  - List worklogs (with ids)
  - Search Azure DevOps work items by free text (to resolve a name -> id)
  - Set up credentials interactively (--auth)

Requires:
  - Python 3.8+
  - requests (pip install requests)
  - A 7pace API token (Bearer). For --search also an Azure DevOps PAT.

7pace API reference: https://timehub.7pace.com/api_reference/index.html
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import quote

import requests

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_BASE_URL = "https://dagrofa.timehub.7pace.com"
API_VERSION = "3.2"
DEFAULT_CONFIG_PATH = Path.home() / ".7pace" / "config.json"

# English weekday tokens (abbreviation + full name) -> Python weekday() index (Mon=0)
WEEKDAY_MAP = {
    "mon": 0, "monday": 0,
    "tue": 1, "tuesday": 1,
    "wed": 2, "wednesday": 2,
    "thu": 3, "thursday": 3,
    "fri": 4, "friday": 4,
    "sat": 5, "saturday": 5,
    "sun": 6, "sunday": 6,
}
WEEKDAY_NAMES = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

MONTHS = {
    "january": 1, "february": 2, "march": 3, "april": 4,
    "may": 5, "june": 6, "july": 7, "august": 8,
    "september": 9, "october": 10, "november": 11, "december": 12,
}


# ---------------------------------------------------------------------------
# Config / Auth
# ---------------------------------------------------------------------------

def load_config(config_path: Path) -> dict:
    if not config_path.exists():
        return {}
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"Warning: could not read config file {config_path}: {e}", file=sys.stderr)
        return {}


def get_auth_from_config(config: dict) -> Tuple[str, Optional[str], Optional[str]]:
    auth = config.get("auth", {})
    auth_type = auth.get("type", "bearer").lower()
    # 7pace authenticates with a Bearer API token. "token"/"bearer"/"pat" all resolve to a Bearer token.
    if auth_type in ("bearer", "token", "pat"):
        token = (auth.get("token") or auth.get("pat")
                 or os.environ.get("SEVENPACE_TOKEN") or os.environ.get("SEVENPACE_PAT"))
        return ("bearer", token, None)
    if auth_type == "basic":
        user = auth.get("username") or os.environ.get("SEVENPACE_USERNAME")
        pw = auth.get("password") or os.environ.get("SEVENPACE_PASSWORD")
        return ("basic", user, pw)
    return ("bearer", None, None)


def resolve_config_value(args_value, config_key: str, env_key: str, config: dict, default=None):
    if args_value is not None and args_value != default:
        return args_value
    env_val = os.environ.get(env_key)
    if env_val is not None:
        return env_val
    return config.get(config_key, default)


def create_default_config(path: Path):
    template = {
        "auth": {
            "type": "bearer",
            "token": "PASTE_7PACE_API_TOKEN_HERE"
        },
        "base_url": DEFAULT_BASE_URL,
        "api_version": API_VERSION,
        "azure_devops": {
            "pat": "PASTE_AZURE_DEVOPS_PAT_HERE",
            "organization": "Dagrofa",
            "project": None
        },
        "defaults": {
            "work_item_id": 32933,
            "comment": "Work"
        }
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(template, f, indent=2, ensure_ascii=False)
    print(f"Created template config file: {path}")
    print("Edit the file and paste your tokens (or run --auth).")
    sys.exit(0)


# ---------------------------------------------------------------------------
# Interactive auth setup (writes tokens to config)
# ---------------------------------------------------------------------------

def run_auth_setup(config_path: Path, reader=input, secret_reader=None) -> Path:
    """Prompt for credentials and save them to config_path.
    `reader`/`secret_reader` can be injected in tests. Secrets are read hidden."""
    import getpass
    if secret_reader is None:
        secret_reader = getpass.getpass
    existing = load_config(config_path)
    ex_auth = existing.get("auth", {}) or {}
    ex_azdo = existing.get("azure_devops", {}) or {}
    ex_def = existing.get("defaults", {}) or {}

    print(f"7pace Time Tracker - setup. Config will be saved to: {config_path}")
    acct = reader("Azure DevOps account name (e.g. 'dagrofa'), or Enter to type the full URL: ").strip()
    if acct:
        base_url = f"https://{acct}.timehub.7pace.com"
    else:
        default_base = existing.get("base_url", DEFAULT_BASE_URL)
        base_url = reader(f"7pace base URL [{default_base}]: ").strip() or default_base

    token = secret_reader("7pace API token (Bearer, hidden): ").strip() or ex_auth.get("token", "")
    org = reader(f"Azure DevOps organization for search [{ex_azdo.get('organization', '')}]: ").strip() \
        or ex_azdo.get("organization", "")
    azdo_pat = secret_reader("Azure DevOps PAT for search (optional, Enter to skip): ").strip() \
        or ex_azdo.get("pat", "")
    project = reader("Limit search to one project (Enter = org-wide): ").strip() or None
    wi = reader(f"Default work item ID (optional) [{ex_def.get('work_item_id', '')}]: ").strip()
    comment = reader(f"Default comment [{ex_def.get('comment', 'Work')}]: ").strip() \
        or ex_def.get("comment", "Work")

    cfg = {
        "auth": {"type": "bearer", "token": token},
        "base_url": base_url,
        "api_version": existing.get("api_version", API_VERSION),
        "azure_devops": {"organization": org, "project": project},
        "defaults": {"comment": comment},
    }
    if azdo_pat:
        cfg["azure_devops"]["pat"] = azdo_pat
    if wi:
        try:
            cfg["defaults"]["work_item_id"] = int(wi)
        except ValueError:
            pass
    elif ex_def.get("work_item_id"):
        cfg["defaults"]["work_item_id"] = ex_def["work_item_id"]

    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(cfg, indent=2, ensure_ascii=False), encoding="utf-8")
    try:
        os.chmod(config_path, 0o600)  # best-effort on POSIX
    except Exception:
        pass
    return config_path


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def parse_date(date_str: str) -> datetime.date:
    date_str = date_str.strip().lower()
    today = datetime.date.today()
    if date_str in ("today", "now"):
        return today
    if date_str in ("yesterday",):
        return today - datetime.timedelta(days=1)
    if date_str in MONTHS:
        month = MONTHS[date_str]
        year = today.year
        if month > today.month:
            year -= 1
        return datetime.date(year, month, 1)
    for fmt in ("%Y-%m-%d", "%d-%m-%Y", "%d/%m/%Y", "%d/%m-%Y"):
        try:
            return datetime.datetime.strptime(date_str, fmt).date()
        except ValueError:
            pass
    raise ValueError(f"Cannot parse date: {date_str}")


def parse_weekday_hours(spec: str) -> Dict[int, float]:
    """Parse a per-weekday hours spec, e.g. '7.5 mon-thu and 7.0 fri' or '7.5 all'."""
    result: Dict[int, float] = {}
    spec = spec.lower().strip()
    if spec in ("all", "all weekdays", "all days"):
        return {i: 7.5 for i in range(5)}
    # accept both 'and' (English) and 'og' (legacy) as the separator
    spec = spec.replace(" og ", " and ")
    parts = [p.strip() for p in spec.split(" and ")]
    for part in parts:
        tokens = part.split()
        if not tokens:
            continue
        hours = float(tokens[0].replace(",", ".").replace(":", "."))
        day_spec = " ".join(tokens[1:])
        if "-" in day_spec:
            start_str, end_str = day_spec.split("-", 1)
            start = WEEKDAY_MAP.get(start_str.strip())
            end = WEEKDAY_MAP.get(end_str.strip())
            if start is None or end is None:
                raise ValueError(f"Unknown weekday range: {day_spec}")
            for d in range(start, end + 1):
                result[d] = hours
        else:
            for d in day_spec.replace(",", " ").split():
                weekday = WEEKDAY_MAP.get(d.strip())
                if weekday is None:
                    raise ValueError(f"Unknown weekday: {d}")
                result[weekday] = hours
    return result


def get_weekdays(start_date: datetime.date, end_date: datetime.date,
                 weekday_hours: Dict[int, float]) -> List[Tuple[datetime.date, float]]:
    result = []
    current = start_date
    while current <= end_date:
        weekday = current.weekday()
        if weekday in weekday_hours:
            result.append((current, weekday_hours[weekday]))
        current += datetime.timedelta(days=1)
    return result


def _build_worklog_payload(date: datetime.date, hours: float, work_item_id: int,
                           comment: str, activity_type_id: Optional[str] = None,
                           billable_hours: Optional[float] = None) -> dict:
    timestamp = datetime.datetime(date.year, date.month, date.day, 8, 0, 0).isoformat()
    length_seconds = int(hours * 3600)
    payload = {
        "timeStamp": timestamp,
        "length": length_seconds,
        "workItemId": work_item_id,
        "comment": comment,
    }
    if billable_hours is not None:
        payload["billableLength"] = int(billable_hours * 3600)
    if activity_type_id:
        payload["activityTypeId"] = activity_type_id
    return payload


# ---------------------------------------------------------------------------
# Azure DevOps work item search (free text -> id)
# ---------------------------------------------------------------------------

def azdo_search_work_items(text: str, pat: str, organization: str,
                           project: Optional[str], top: int = 50) -> List[dict]:
    """Search work items by free text in the title via Azure DevOps WIQL.
    Returns a list of {id, title, type, state, project}. Requires an Azure DevOps PAT."""
    safe = text.replace("'", "''")
    where = f"[System.Title] CONTAINS '{safe}'"
    if project:
        where += f" AND [System.TeamProject] = '{project.replace(chr(39), chr(39) * 2)}'"
    wiql = {"query": f"SELECT [System.Id] FROM workitems WHERE {where} "
                     f"ORDER BY [System.ChangedDate] DESC"}
    auth = ("", pat)
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    org_url = f"https://dev.azure.com/{organization}"
    proj_seg = f"/{quote(project, safe='')}" if project else ""
    r = requests.post(f"{org_url}{proj_seg}/_apis/wit/wiql?api-version=7.1",
                      auth=auth, headers=headers, json=wiql, timeout=30)
    r.raise_for_status()
    ids = [w["id"] for w in r.json().get("workItems", [])][:top]
    if not ids:
        return []
    ids_param = ",".join(str(i) for i in ids)
    fields = "System.Id,System.Title,System.WorkItemType,System.State,System.TeamProject"
    r2 = requests.get(
        f"{org_url}/_apis/wit/workitems?ids={ids_param}&fields={fields}&api-version=7.1",
        auth=auth, headers=headers, timeout=30)
    r2.raise_for_status()
    out = []
    for it in r2.json().get("value", []):
        f = it.get("fields", {})
        out.append({"id": it.get("id"),
                    "title": f.get("System.Title"),
                    "type": f.get("System.WorkItemType"),
                    "state": f.get("System.State"),
                    "project": f.get("System.TeamProject")})
    return out


# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------

class SevenPaceClient:
    def __init__(self, base_url: str, api_version: str = API_VERSION,
                 token: Optional[str] = None,
                 username: Optional[str] = None,
                 password: Optional[str] = None):
        self.base_url = base_url.rstrip("/")
        self.api_version = api_version
        self.headers = {"Content-Type": "application/json", "Accept": "application/json"}
        self.auth = None
        if token:
            # 7pace authenticates with a Bearer API token.
            self.headers["Authorization"] = f"Bearer {token}"
        elif username and password:
            self.auth = (username, password)
        else:
            raise ValueError("Provide either a 7pace API token or username/password")

    def _url(self, path: str) -> str:
        return f"{self.base_url}{path}?api-version={self.api_version}"

    def get_me(self) -> dict:
        resp = requests.get(self._url("/api/rest/me"), auth=self.auth, headers=self.headers)
        resp.raise_for_status()
        return resp.json()

    def get_worklogs(self, from_date: datetime.date, to_date: datetime.date,
                     skip: int = 0, count: int = 500) -> List[dict]:
        from_ts = datetime.datetime(from_date.year, from_date.month, from_date.day).isoformat()
        to_ts = datetime.datetime(to_date.year, to_date.month, to_date.day, 23, 59, 59).isoformat()
        resp = requests.get(
            self._url("/api/rest/workLogs"),
            auth=self.auth, headers=self.headers,
            params={"fromTimestamp": from_ts, "toTimestamp": to_ts, "skip": skip, "count": count},
        )
        resp.raise_for_status()
        return resp.json().get("data", [])

    def get_worklog(self, worklog_id: str) -> dict:
        resp = requests.get(self._url(f"/api/rest/workLogs/{worklog_id}"),
                            auth=self.auth, headers=self.headers)
        resp.raise_for_status()
        return resp.json()

    def create_worklog(self, date: datetime.date, hours: float, work_item_id: int,
                       comment: str, activity_type_id: Optional[str] = None,
                       billable_hours: Optional[float] = None) -> dict:
        payload = _build_worklog_payload(date, hours, work_item_id, comment,
                                          activity_type_id, billable_hours)
        resp = requests.post(self._url("/api/rest/workLogs"), auth=self.auth,
                             headers=self.headers, json=payload)
        resp.raise_for_status()
        return resp.json()

    def create_worklogs_batch(self, entries: List[dict]) -> dict:
        """entries: list of dicts with timeStamp, length, workItemId, comment, etc."""
        resp = requests.post(
            self._url("/api/rest/workLogs/batch"),
            auth=self.auth, headers=self.headers,
            json={"workLogs": entries},
        )
        resp.raise_for_status()
        return resp.json()

    def update_worklog(self, worklog_id: str, **kwargs) -> dict:
        """Update a worklog. kwargs may be: timeStamp, length, workItemId, comment, activityTypeId, billableLength."""
        resp = requests.patch(
            self._url(f"/api/rest/workLogs/{worklog_id}"),
            auth=self.auth, headers=self.headers,
            json=kwargs,
        )
        resp.raise_for_status()
        return resp.json()

    def delete_worklog(self, worklog_id: str) -> dict:
        resp = requests.delete(
            self._url(f"/api/rest/workLogs/{worklog_id}"),
            auth=self.auth, headers=self.headers,
        )
        resp.raise_for_status()
        # DELETE returns 204 No Content / empty body - don't try to parse JSON.
        if resp.status_code == 204 or not resp.text.strip():
            return {"status": "deleted", "id": worklog_id}
        return resp.json()


# ---------------------------------------------------------------------------
# Main program
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="7pace Time Tracker API client",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Single day
  python timetracker.py --date 2026-04-09 --hours 4 \\
      --work-item 32933 --comment "Work" --yes --json

  # Date range with a per-weekday pattern
  python timetracker.py --from 2026-04-01 --to today \\
      --hours "7.5 mon-thu and 7.0 fri" \\
      --work-item 32933 --comment "Work" --yes --json

  # Search a work item by name
  python timetracker.py --search "Nordisk Film" --json

  # Update / delete
  python timetracker.py --update WORKLOG_ID --hours 8 --yes --json
  python timetracker.py --delete WORKLOG_ID --yes --json

  # First-time credential setup
  python timetracker.py --auth
        """
    )

    # Date / hours
    parser.add_argument("--date", "-d", default=None,
                        help="Single date (e.g. '2026-04-09', 'today')")
    parser.add_argument("--from", "-f", dest="start_date", default=None,
                        help="Start date (batch mode)")
    parser.add_argument("--to", "-t", dest="end_date", default=None,
                        help="End date (batch mode)")
    parser.add_argument("--hours", "-H", default=None,
                        help="Hours (single: 7.5; batch: '7.5 mon-thu and 7.0 fri')")

    # Worklog data
    parser.add_argument("--work-item", "-w", type=int, default=None, help="Work item ID")
    parser.add_argument("--comment", "-c", default=None, help="Comment")
    parser.add_argument("--activity-type-id", default=None, help="Activity type UUID")

    # CRUD operations
    parser.add_argument("--update", default=None, help="Worklog ID to update")
    parser.add_argument("--delete", dest="delete_id", default=None, help="Worklog ID to delete")
    parser.add_argument("--list", dest="list_mode", action="store_true",
                        help="List worklogs in a range (--date or --from/--to) with ids")
    parser.add_argument("--search", default=None,
                        help="Search work items by free text in the title (returns matching ids)")
    parser.add_argument("--azdo-pat", default=None,
                        help="Azure DevOps PAT for work item search (overrides config)")
    parser.add_argument("--project", default=None,
                        help="Limit --search to one ADO project (default: org-wide across all projects)")

    # Auth
    parser.add_argument("--pat", "-p", default=None, help="7pace Bearer token")
    parser.add_argument("--token", default=None, help="7pace Bearer token (alias of --pat)")
    parser.add_argument("--username", "-U", default=None, help="Basic auth username")
    parser.add_argument("--password", "-P", default=None, help="Basic auth password")
    parser.add_argument("--base-url", "-u", default=None, help="API base URL")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH), help="Path to config file")
    parser.add_argument("--init-config", action="store_true", help="Create a template config file")
    parser.add_argument("--auth", action="store_true",
                        help="Interactive setup: enter credentials (hidden) and save them to config")

    # Behavior
    parser.add_argument("--yes", "-y", action="store_true", help="Confirm automatically (no prompt)")
    parser.add_argument("--json", "-j", action="store_true", help="Output as JSON")
    parser.add_argument("--dry-run", action="store_true", help="Simulate without creating")
    parser.add_argument("--skip-existing", action="store_true", default=True,
                        help="Skip days that already have time")
    parser.add_argument("--no-skip-existing", action="store_true", help="Overwrite existing")

    args = parser.parse_args()

    if args.init_config:
        create_default_config(Path(args.config))

    if args.auth:
        path = run_auth_setup(Path(args.config))
        _ok({"status": "configured", "config_path": str(path)}, args.json)

    config = load_config(Path(args.config))
    base_url = resolve_config_value(args.base_url, "base_url", "SEVENPACE_BASE_URL",
                                    config, DEFAULT_BASE_URL)
    api_version = resolve_config_value(None, "api_version", "SEVENPACE_API_VERSION",
                                       config, API_VERSION)

    # SEARCH mode (Azure DevOps work item free-text search) - needs only an ADO PAT, not the 7pace token
    if args.search is not None:
        azdo = config.get("azure_devops", {})
        azdo_pat = args.azdo_pat or azdo.get("pat") or os.environ.get("AZDO_PAT")
        azdo_org = azdo.get("organization") or "Dagrofa"
        azdo_project = args.project if args.project is not None else azdo.get("project")
        if not azdo_pat:
            _error("Search requires an Azure DevOps PAT. Add 'azure_devops.pat' to config "
                   "or set the AZDO_PAT environment variable.", args.json)
        try:
            matches = azdo_search_work_items(args.search, azdo_pat, azdo_org, azdo_project)
        except Exception as e:
            _error(f"Search failed: {e}", args.json)
        _ok({"status": "ok", "query": args.search, "count": len(matches),
             "matches": matches}, args.json)
        return

    auth_type, auth_user, auth_pw = get_auth_from_config(config)
    token_arg = args.pat or args.token
    if token_arg:
        auth_type, auth_user, auth_pw = "bearer", token_arg, None
    elif args.username and args.password:
        auth_type, auth_user, auth_pw = "basic", args.username, args.password
    elif args.username:
        pw = os.environ.get("SEVENPACE_PASSWORD")
        if pw:
            auth_type, auth_user, auth_pw = "basic", args.username, pw

    if not auth_user:
        _error("No authentication configured. Use --auth, --pat/--token, --username/--password, "
               "the SEVENPACE_TOKEN environment variable, or a config file.", args.json)

    defaults = config.get("defaults", {})
    work_item = resolve_config_value(args.work_item, "work_item_id", "SEVENPACE_WORK_ITEM",
                                     {**defaults, **config}, None)
    comment = resolve_config_value(args.comment, "comment", "SEVENPACE_COMMENT",
                                   {**defaults, **config}, None)

    client = SevenPaceClient(
        base_url=base_url, api_version=api_version,
        token=auth_user if auth_type == "bearer" else None,
        username=auth_user if auth_type == "basic" else None,
        password=auth_pw if auth_type == "basic" else None,
    )

    # Auth check
    try:
        client.get_me()
    except Exception as e:
        _error(f"Could not connect: {e}", args.json)

    # LIST mode
    if args.list_mode:
        try:
            if args.date:
                ls = le = parse_date(args.date)
            elif args.start_date and args.end_date:
                ls = parse_date(args.start_date)
                le = parse_date(args.end_date)
            else:
                _error("--list requires --date or --from/--to", args.json)
        except ValueError as e:
            _error(str(e), args.json)
        try:
            wls = client.get_worklogs(ls, le)
        except Exception as e:
            _error(f"Could not fetch worklogs: {e}", args.json)
        out = [{"id": w.get("id"),
                "date": (w.get("timestamp") or w.get("timeStamp") or "")[:10],
                "hours": w.get("length", 0) / 3600,
                "work_item_id": w.get("workItemId"),
                "comment": w.get("comment")} for w in wls]
        _ok({"status": "ok", "count": len(out), "worklogs": out}, args.json)
        return

    # DELETE mode
    if args.delete_id:
        if not args.yes:
            _error("--delete requires --yes to confirm", args.json)
        if args.dry_run:
            _ok({"status": "dry_run", "action": "delete", "worklog_id": args.delete_id}, args.json)
        try:
            client.delete_worklog(args.delete_id)
            _ok({"status": "deleted", "worklog_id": args.delete_id}, args.json)
        except Exception as e:
            _error(f"Delete failed: {e}", args.json)
        return

    # UPDATE mode
    if args.update:
        if not args.yes:
            _error("--update requires --yes to confirm", args.json)
        if not args.hours:
            _error("--update requires --hours", args.json)
        try:
            hours = float(args.hours.replace(",", ".").replace(":", "."))
        except ValueError:
            _error(f"Invalid hours value: {args.hours}", args.json)
        if args.dry_run:
            _ok({"status": "dry_run", "action": "update", "worklog_id": args.update,
                 "hours": hours}, args.json)
        try:
            payload = {"length": int(hours * 3600)}
            if comment:
                payload["comment"] = comment
            if work_item:
                payload["workItemId"] = work_item
            if args.activity_type_id:
                payload["activityTypeId"] = args.activity_type_id
            result = client.update_worklog(args.update, **payload)
            _ok({"status": "updated", "worklog_id": args.update, "data": result.get("data", {})}, args.json)
        except Exception as e:
            _error(f"Update failed: {e}", args.json)
        return

    # CREATE mode (single or batch)
    single_mode = bool(args.date)
    batch_mode = bool(args.start_date and args.end_date)

    if not single_mode and not batch_mode:
        _error("Provide either --date (single) or --from + --to (batch)", args.json)
    if not work_item:
        _error("--work-item is required", args.json)
    if not comment:
        _error("--comment is required", args.json)
    if not args.hours:
        _error("--hours is required", args.json)

    if single_mode:
        try:
            target_date = parse_date(args.date)
        except ValueError as e:
            _error(str(e), args.json)
        try:
            hours = float(args.hours.replace(",", ".").replace(":", "."))
        except ValueError:
            _error(f"Invalid hours value: {args.hours}", args.json)
        days = [(target_date, hours)]
        start_date = end_date = target_date
    else:
        try:
            start_date = parse_date(args.start_date)
            end_date = parse_date(args.end_date)
        except ValueError as e:
            _error(str(e), args.json)
        if start_date > end_date:
            _error("Start date cannot be after end date", args.json)
        try:
            weekday_hours = parse_weekday_hours(args.hours)
        except ValueError as e:
            _error(f"Error in hours spec: {e}", args.json)
        days = get_weekdays(start_date, end_date, weekday_hours)

    if not days:
        _ok({"status": "nothing_to_do", "message": "No days to register"}, args.json)

    # Check existing
    skip_existing = args.skip_existing and not args.no_skip_existing
    existing: List[dict] = []
    if skip_existing:
        try:
            existing = client.get_worklogs(start_date, end_date)
        except Exception:
            existing = []

    existing_dates: set = set()
    for wl in existing:
        ts_str = wl.get("timestamp") or wl.get("timeStamp")
        if ts_str:
            try:
                dt = datetime.datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                existing_dates.add(dt.date())
            except Exception:
                pass

    # Build entries
    entries_to_create: List[dict] = []
    skipped: List[datetime.date] = []
    for date, hours in days:
        if skip_existing and date in existing_dates:
            skipped.append(date)
            continue
        entries_to_create.append(_build_worklog_payload(
            date, hours, work_item, comment, args.activity_type_id, None))

    # Dry run
    if args.dry_run:
        _ok({
            "status": "dry_run",
            "entries": [{"date": e["timeStamp"][:10], "hours": e["length"] / 3600,
                         "work_item_id": e["workItemId"], "comment": e["comment"]}
                        for e in entries_to_create],
            "skipped": [str(d) for d in skipped],
            "total_hours": sum(e["length"] / 3600 for e in entries_to_create),
        }, args.json)

    # Confirm
    if not args.yes and not args.json:
        print(f"About to create {len(entries_to_create)} time entries")
        if entries_to_create:
            print(f"First: {entries_to_create[0]['timeStamp'][:10]} ({entries_to_create[0]['length'] / 3600} hours)")
            if len(entries_to_create) > 1:
                print(f"Last:  {entries_to_create[-1]['timeStamp'][:10]} ({entries_to_create[-1]['length'] / 3600} hours)")
        confirm = input("Confirm (yes/no): ").strip().lower()
        if confirm not in ("yes", "y"):
            print("Aborted.")
            sys.exit(0)

    # Create
    success = []
    failed = []
    try:
        if len(entries_to_create) > 1:
            if not args.json:
                print(f"Creating {len(entries_to_create)} entries via batch API...")
            result = client.create_worklogs_batch(entries_to_create)
            success = result.get("data", [])
        else:
            for entry in entries_to_create:
                try:
                    result = client.create_worklog(
                        datetime.date.fromisoformat(entry["timeStamp"][:10]),
                        entry["length"] / 3600,
                        entry["workItemId"],
                        entry["comment"],
                        entry.get("activityTypeId"),
                    )
                    success.append(result.get("data", {}))
                except Exception as e:
                    failed.append((entry["timeStamp"][:10], str(e)))
    except Exception as e:
        if not args.json:
            print(f"Batch error: {e}, retrying one by one...")
        for entry in entries_to_create:
            try:
                result = client.create_worklog(
                    datetime.date.fromisoformat(entry["timeStamp"][:10]),
                    entry["length"] / 3600,
                    entry["workItemId"],
                    entry["comment"],
                    entry.get("activityTypeId"),
                )
                success.append(result.get("data", {}))
            except Exception as e2:
                failed.append((entry["timeStamp"][:10], str(e2)))

    total_hours = sum(e["length"] / 3600 for e in entries_to_create)
    if args.json:
        _ok({
            "status": "success" if not failed else "partial",
            "created": len(success),
            "failed": len(failed),
            "skipped": len(skipped),
            "total_hours": total_hours,
            "entries": [{"date": e["timeStamp"][:10], "hours": e["length"] / 3600,
                         "work_item_id": e["workItemId"], "comment": e["comment"]}
                        for e in entries_to_create],
            "failures": [{"date": d, "error": err} for d, err in failed],
        }, args.json)
    else:
        print(f"\nCreated: {len(success)} | Failed: {len(failed)} | Skipped: {len(skipped)} | Total: {total_hours} hours")
        if failed:
            for d, err in failed:
                print(f"  x {d}: {err}")
            sys.exit(1)


def _ok(data: dict, json_output: bool):
    if json_output:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        for k, v in data.items():
            print(f"  {k}: {v}")
    sys.exit(0)


def _error(msg: str, json_output: bool):
    if json_output:
        print(json.dumps({"status": "error", "message": msg}, ensure_ascii=False))
    else:
        print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
