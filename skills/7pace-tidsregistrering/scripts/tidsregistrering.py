#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
7pace Timetracker - API Client Script

Kaldes direkte fra LLM-agenter for at:
  - Oprette tidregistreringer (single-day eller batch)
  - Opdatere eksisterende worklogs
  - Slette worklogs

Kræver:
  - Python 3.7+
  - requests (pip install requests)
  - Azure DevOps PAT / basic auth

7pace API Reference:
  https://timehub.7pace.com/api_reference/index.html
"""

import argparse
import datetime
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import quote

import requests

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

DEFAULT_BASE_URL = "https://dagrofa.timehub.7pace.com"
API_VERSION = "3.2"
DEFAULT_CONFIG_PATH = Path.home() / ".7pace" / "config.json"

WEEKDAY_MAP = {
    "man": 0, "mandag": 0,
    "tir": 1, "tirsdag": 1,
    "ons": 2, "onsdag": 2,
    "tor": 3, "torsdag": 3,
    "fre": 4, "fredag": 4,
    "lør": 5, "lørdag": 5,
    "søn": 6, "søndag": 6,
}
WEEKDAY_NAMES = ["mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag", "søndag"]


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
        print(f"Advarsel: Kunne ikke læse config-fil {config_path}: {e}", file=sys.stderr)
        return {}


def get_auth_from_config(config: dict) -> Tuple[str, Optional[str], Optional[str]]:
    auth = config.get("auth", {})
    auth_type = auth.get("type", "bearer").lower()
    # 7pace Timetracker uses a Bearer API token (generated in Settings > Reporting & API).
    # "token"/"bearer"/"pat" all resolve to a Bearer token here.
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
            "type": "pat",
            "pat": "DIT_AZURE_DEVOPS_PAT_TOKEN_HER"
        },
        "base_url": DEFAULT_BASE_URL,
        "api_version": API_VERSION,
        "defaults": {
            "work_item_id": 32933,
            "comment": "Generelt arbejde"
        }
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(template, f, indent=2, ensure_ascii=False)
    print(f"Oprettede template config-fil: {path}")
    print("Rediger filen og indtast din PAT token.")
    sys.exit(0)


# ---------------------------------------------------------------------------
# Interaktiv auth-opsætning (skriver nøgler til config)
# ---------------------------------------------------------------------------

def run_auth_setup(config_path: Path, reader=input, secret_reader=None) -> Path:
    """Spørg interaktivt efter nøgler og gem dem i config_path.
    `reader`/`secret_reader` kan injiceres i tests. Hemmeligheder læses skjult."""
    import getpass
    if secret_reader is None:
        secret_reader = getpass.getpass
    existing = load_config(config_path)
    ex_auth = existing.get("auth", {}) or {}
    ex_azdo = existing.get("azure_devops", {}) or {}
    ex_def = existing.get("defaults", {}) or {}

    print(f"7pace Timetracker – opsætning. Config gemmes i: {config_path}")
    acct = reader("Azure DevOps konto (fx 'dagrofa'), eller Enter for at indtaste fuld URL: ").strip()
    if acct:
        base_url = f"https://{acct}.timehub.7pace.com"
    else:
        default_base = existing.get("base_url", DEFAULT_BASE_URL)
        base_url = reader(f"7pace base URL [{default_base}]: ").strip() or default_base

    token = secret_reader("7pace API token (Bearer, skjult): ").strip() or ex_auth.get("token", "")
    org = reader(f"Azure DevOps organisation til søgning [{ex_azdo.get('organization', '')}]: ").strip() \
        or ex_azdo.get("organization", "")
    azdo_pat = secret_reader("Azure DevOps PAT til søgning (valgfri, Enter=spring over): ").strip() \
        or ex_azdo.get("pat", "")
    project = reader("Begræns søgning til ét projekt (Enter = org-bredt): ").strip() or None
    wi = reader(f"Standard work item ID (valgfri) [{ex_def.get('work_item_id', '')}]: ").strip()
    comment = reader(f"Standard kommentar [{ex_def.get('comment', 'Arbejde')}]: ").strip() \
        or ex_def.get("comment", "Arbejde")

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
        os.chmod(config_path, 0o600)  # best-effort på POSIX
    except Exception:
        pass
    return config_path


# ---------------------------------------------------------------------------
# Hjælpefunktioner
# ---------------------------------------------------------------------------

def parse_danish_date(date_str: str) -> datetime.date:
    date_str = date_str.strip().lower()
    today = datetime.date.today()
    if date_str in ("dags dato", "idag", "i dag"):
        return today
    danish_months = {
        "januar": 1, "februar": 2, "marts": 3, "april": 4,
        "maj": 5, "juni": 6, "juli": 7, "august": 8,
        "september": 9, "oktober": 10, "november": 11, "december": 12,
    }
    if date_str in danish_months:
        month = danish_months[date_str]
        year = today.year
        if month > today.month:
            year -= 1
        return datetime.date(year, month, 1)
    for fmt in ("%Y-%m-%d", "%d-%m-%Y", "%d/%m-%Y", "%d/%m/%Y"):
        try:
            return datetime.datetime.strptime(date_str, fmt).date()
        except ValueError:
            pass
    raise ValueError(f"Kan ikke parse dato: {date_str}")


def parse_weekday_hours(spec: str) -> Dict[int, float]:
    result: Dict[int, float] = {}
    spec = spec.lower().strip()
    if spec in ("alle", "alle hverdage", "alle dage"):
        return {i: 7.5 for i in range(5)}
    parts = [p.strip() for p in spec.split(" og ")]
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
                raise ValueError(f"Ukendt ugedage interval: {day_spec}")
            for d in range(start, end + 1):
                result[d] = hours
        else:
            for d in day_spec.replace(",", " ").split():
                weekday = WEEKDAY_MAP.get(d.strip())
                if weekday is None:
                    raise ValueError(f"Ukendt ugedag: {d}")
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
# API Client
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
            # 7pace Timetracker authenticates with a Bearer API token.
            self.headers["Authorization"] = f"Bearer {token}"
        elif username and password:
            self.auth = (username, password)
        else:
            raise ValueError("Enten et 7pace API-token eller brugernavn/password skal angives")

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
        """entries: liste af dicts med timeStamp, length, workItemId, comment, etc."""
        resp = requests.post(
            self._url("/api/rest/workLogs/batch"),
            auth=self.auth, headers=self.headers,
            json={"workLogs": entries},
        )
        resp.raise_for_status()
        return resp.json()

    def update_worklog(self, worklog_id: str, **kwargs) -> dict:
        """Opdaterer et worklog. kwargs kan være: timeStamp, length, workItemId, comment, activityTypeId, billableLength."""
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
        # DELETE returns 204 No Content / empty body — don't try to parse JSON.
        if resp.status_code == 204 or not resp.text.strip():
            return {"status": "deleted", "id": worklog_id}
        return resp.json()


# ---------------------------------------------------------------------------
# Azure DevOps work item søgning (fritekst -> ID)
# ---------------------------------------------------------------------------

def azdo_search_work_items(text: str, pat: str, organization: str,
                           project: Optional[str], top: int = 50) -> List[dict]:
    """Søg work items på fritekst i titel via Azure DevOps WIQL.
    Returnerer liste af {id, title, type, state}. Kræver et Azure DevOps PAT."""
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
# Hoved-program
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="7pace Timetracker API klient",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Eksempler:
  # Opret enkelt entry
  python tidsregistrering.py --date "dags dato" --hours 7.5 \\
      --work-item 32933 --comment "Arbejde" --yes --json

  # Opret batch
  python tidsregistrering.py --from "april" --to "dags dato" \\
      --hours "7.5 man-tor og 7.0 fre" \\
      --work-item 32933 --comment "Arbejde" --yes

  # Opdater eksisterende worklog
  python tidsregistrering.py --update WORKLOG_ID --hours 8.0 --yes --json

  # Slet worklog
  python tidsregistrering.py --delete WORKLOG_ID --yes --json

  # Opret config template
  python tidsregistrering.py --init-config
        """
    )

    # Dato / timer
    parser.add_argument("--date", "-d", default=None,
                        help="Enkelt dato (f.eks. '2024-06-08', 'dags dato')")
    parser.add_argument("--from", "-f", dest="start_date", default=None,
                        help="Startdato (batch mode)")
    parser.add_argument("--to", "-t", dest="end_date", default=None,
                        help="Slutdato (batch mode)")
    parser.add_argument("--hours", "-H", default=None,
                        help="Timer (batch: '7.5 man-tor og 7.0 fre', single: 7.5)")

    # Worklog data
    parser.add_argument("--work-item", "-w", type=int, default=None,
                        help="Work item ID")
    parser.add_argument("--comment", "-c", default=None,
                        help="Kommentar")
    parser.add_argument("--activity-type-id", default=None,
                        help="Activity type UUID")

    # CRUD operationer
    parser.add_argument("--update", default=None,
                        help="Worklog ID at opdatere")
    parser.add_argument("--delete", dest="delete_id", default=None,
                        help="Worklog ID at slette")
    parser.add_argument("--list", dest="list_mode", action="store_true",
                        help="List worklogs i interval (--date eller --from/--to) med id'er")
    parser.add_argument("--search", default=None,
                        help="Søg work items på fritekst i titel (returnerer matchende id'er)")
    parser.add_argument("--azdo-pat", default=None,
                        help="Azure DevOps PAT til work item-søgning (overstyrer config)")
    parser.add_argument("--project", default=None,
                        help="Begræns --search til ét ADO-projekt (default: org-bred på tværs af alle projekter)")

    # Auth
    parser.add_argument("--pat", "-p", default=None, help="PAT token")
    parser.add_argument("--username", "-U", default=None, help="Basic auth brugernavn")
    parser.add_argument("--password", "-P", default=None, help="Basic auth password")
    parser.add_argument("--base-url", "-u", default=None, help="API base URL")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH),
                        help="Sti til config-fil")
    parser.add_argument("--init-config", action="store_true",
                        help="Opret template config-fil")
    parser.add_argument("--auth", action="store_true",
                        help="Interaktiv opsætning: indtast nøgler (skjult) og gem dem i config")

    # Behavior
    parser.add_argument("--yes", "-y", action="store_true",
                        help="Bekræft automatisk (ingen prompt)")
    parser.add_argument("--json", "-j", action="store_true",
                        help="Output som JSON")
    parser.add_argument("--dry-run", action="store_true",
                        help="Simuler uden at oprette")
    parser.add_argument("--skip-existing", action="store_true", default=True,
                        help="Spring over dage med eksisterende tid")
    parser.add_argument("--no-skip-existing", action="store_true",
                        help="Overskriv eksisterende")

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

    # SEARCH mode (Azure DevOps work item fritekst-søgning) — kræver kun et ADO PAT, ikke 7pace-token
    if args.search is not None:
        azdo = config.get("azure_devops", {})
        azdo_pat = args.azdo_pat or azdo.get("pat") or os.environ.get("AZDO_PAT")
        azdo_org = azdo.get("organization") or "Dagrofa"
        # --project overstyrer config; ellers config (null = org-bred, anbefalet default)
        azdo_project = args.project if args.project is not None else azdo.get("project")
        if not azdo_pat:
            _error("Søgning kræver et Azure DevOps PAT. Tilføj 'azure_devops.pat' i config "
                   "eller sæt AZDO_PAT miljøvariabel.", args.json)
        try:
            matches = azdo_search_work_items(args.search, azdo_pat, azdo_org, azdo_project)
        except Exception as e:
            _error(f"Søgning fejlet: {e}", args.json)
        _ok({"status": "ok", "query": args.search, "count": len(matches),
             "matches": matches}, args.json)
        return

    auth_type, auth_user, auth_pw = get_auth_from_config(config)
    if args.pat:
        auth_type, auth_user, auth_pw = "pat", args.pat, None
    elif args.username and args.password:
        auth_type, auth_user, auth_pw = "basic", args.username, args.password
    elif args.username:
        pw = os.environ.get("SEVENPACE_PASSWORD")
        if pw:
            auth_type, auth_user, auth_pw = "basic", args.username, pw

    if not auth_user:
        _error("Ingen autentificering konfigureret. Brug --pat, --username/--password, "
               "SEVENPACE_PAT miljøvariabel, eller config-fil.", args.json)

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
        me = client.get_me()
        user = me.get("data", {}).get("user", {})
    except Exception as e:
        _error(f"Kunne ikke forbinde: {e}", args.json)

    # LIST mode
    if args.list_mode:
        try:
            if args.date:
                ls = le = parse_danish_date(args.date)
            elif args.start_date and args.end_date:
                ls = parse_danish_date(args.start_date)
                le = parse_danish_date(args.end_date)
            else:
                _error("--list kræver --date eller --from/--to", args.json)
        except ValueError as e:
            _error(str(e), args.json)
        try:
            wls = client.get_worklogs(ls, le)
        except Exception as e:
            _error(f"Kunne ikke hente worklogs: {e}", args.json)
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
            _error("--delete kræver --yes for at bekræfte", args.json)
        if args.dry_run:
            _ok({"status": "dry_run", "action": "delete", "worklog_id": args.delete_id}, args.json)
        try:
            client.delete_worklog(args.delete_id)
            _ok({"status": "deleted", "worklog_id": args.delete_id}, args.json)
        except Exception as e:
            _error(f"Sletning fejlet: {e}", args.json)
        return

    # UPDATE mode
    if args.update:
        if not args.yes:
            _error("--update kræver --yes for at bekræfte", args.json)
        if not args.hours:
            _error("--update kræver --hours", args.json)
        try:
            hours = float(args.hours.replace(",", ".").replace(":", "."))
        except ValueError:
            _error(f"Ugyldigt timeantal: {args.hours}", args.json)
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
            _error(f"Opdatering fejlet: {e}", args.json)
        return

    # CREATE mode (single or batch)
    single_mode = bool(args.date)
    batch_mode = bool(args.start_date and args.end_date)

    if not single_mode and not batch_mode:
        _error("Angiv enten --date (single) eller --from + --to (batch)", args.json)

    if not work_item:
        _error("--work-item er påkrævet", args.json)
    if not comment:
        _error("--comment er påkrævet", args.json)
    if not args.hours:
        _error("--hours er påkrævet", args.json)

    if single_mode:
        try:
            target_date = parse_danish_date(args.date)
        except ValueError as e:
            _error(str(e), args.json)
        try:
            hours = float(args.hours.replace(",", ".").replace(":", "."))
        except ValueError:
            _error(f"Ugyldigt timeantal: {args.hours}", args.json)
        days = [(target_date, hours)]
        start_date = end_date = target_date
    else:
        try:
            start_date = parse_danish_date(args.start_date)
            end_date = parse_danish_date(args.end_date)
        except ValueError as e:
            _error(str(e), args.json)
        if start_date > end_date:
            _error("Startdato kan ikke være efter slutdato", args.json)
        try:
            weekday_hours = parse_weekday_hours(args.hours)
        except ValueError as e:
            _error(f"Fejl i timer-specifikation: {e}", args.json)
        days = get_weekdays(start_date, end_date, weekday_hours)

    if not days:
        _ok({"status": "nothing_to_do", "message": "Ingen dage at registrere"}, args.json)

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
            except:
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
        print(f"Oprettelse af {len(entries_to_create)} tidregistreringer")
        if entries_to_create:
            print(f"Første: {entries_to_create[0]['timeStamp'][:10]} ({entries_to_create[0]['length'] / 3600} timer)")
            if len(entries_to_create) > 1:
                print(f"Sidste: {entries_to_create[-1]['timeStamp'][:10]} ({entries_to_create[-1]['length'] / 3600} timer)")
        confirm = input("Bekræft (ja/nej): ").strip().lower()
        if confirm not in ("ja", "j", "yes", "y"):
            print("Afbrudt.")
            sys.exit(0)

    # Create
    success = []
    failed = []
    try:
        if len(entries_to_create) > 1:
            if not args.json:
                print(f"Opretter {len(entries_to_create)} registreringer via batch API...")
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
            print(f"Batch fejl: {e}, forsøger enkeltvis...")
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
        print(f"\nOprettet: {len(success)} | Fejlet: {len(failed)} | Sprunget over: {len(skipped)} | Total: {total_hours} timer")
        if failed:
            for d, err in failed:
                print(f"  ✗ {d}: {err}")
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
        print(f"Fejl: {msg}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
