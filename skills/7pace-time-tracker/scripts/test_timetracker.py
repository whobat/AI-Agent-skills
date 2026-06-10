#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Tests for timetracker.py

Unit tests (no network):
    python -m unittest test_timetracker -v

All tests incl. live 7pace/ADO API (needs a valid config.json):
    RUN_INTEGRATION=1 python -m unittest test_timetracker -v
    (PowerShell:  $env:RUN_INTEGRATION=1; python -m unittest test_timetracker -v)

Integration tests create/delete only on a safe future date (2031-12-31) and clean up.
"""

import datetime
import json
import os
import unittest
from pathlib import Path

import timetracker as tr

CONFIG_PATH = Path(__file__).with_name("config.json")
TEST_DATE = datetime.date(2031, 12, 31)
# Integration tests need a work item that exists in YOUR tenant: set the
# SEVENPACE_TEST_WORK_ITEM env var, or defaults.work_item_id in config.json.
MARKER = "UNITTEST - safe to delete"


# ===========================================================================
# UNIT TESTS (no network)
# ===========================================================================

class TestParseDate(unittest.TestCase):
    def test_iso(self):
        self.assertEqual(tr.parse_date("2026-06-08"), datetime.date(2026, 6, 8))

    def test_eu_formats(self):
        self.assertEqual(tr.parse_date("08-06-2026"), datetime.date(2026, 6, 8))
        self.assertEqual(tr.parse_date("08/06/2026"), datetime.date(2026, 6, 8))

    def test_today_yesterday(self):
        today = datetime.date.today()
        self.assertEqual(tr.parse_date("today"), today)
        self.assertEqual(tr.parse_date("TODAY"), today)
        self.assertEqual(tr.parse_date("yesterday"), today - datetime.timedelta(days=1))

    def test_month_name(self):
        d = tr.parse_date("april")
        self.assertEqual((d.month, d.day), (4, 1))

    def test_invalid(self):
        with self.assertRaises(ValueError):
            tr.parse_date("not a date")


class TestParseWeekdayHours(unittest.TestCase):
    def test_all(self):
        self.assertEqual(tr.parse_weekday_hours("all"), {0: 7.5, 1: 7.5, 2: 7.5, 3: 7.5, 4: 7.5})

    def test_range_and_single(self):
        self.assertEqual(tr.parse_weekday_hours("7.5 mon-thu and 7.0 fri"),
                         {0: 7.5, 1: 7.5, 2: 7.5, 3: 7.5, 4: 7.0})

    def test_comma_days_and_numbers(self):
        self.assertEqual(tr.parse_weekday_hours("7,5 monday,wednesday"), {0: 7.5, 2: 7.5})

    def test_legacy_og_separator_still_works(self):
        self.assertEqual(tr.parse_weekday_hours("7.5 mon-tue og 7.0 fri"),
                         {0: 7.5, 1: 7.5, 4: 7.0})

    def test_invalid_weekday(self):
        with self.assertRaises(ValueError):
            tr.parse_weekday_hours("7.5 funday")


class TestGetWeekdays(unittest.TestCase):
    def test_skips_weekend(self):
        wh = {0: 7.5, 1: 7.5, 2: 7.5, 3: 7.5, 4: 7.0}
        days = tr.get_weekdays(datetime.date(2026, 6, 1), datetime.date(2026, 6, 7), wh)
        self.assertEqual(len(days), 5)
        weekdays = {d.weekday() for d, _ in days}
        self.assertNotIn(5, weekdays)
        self.assertNotIn(6, weekdays)
        self.assertEqual(days[-1][1], 7.0)

    def test_empty_range(self):
        days = tr.get_weekdays(datetime.date(2026, 6, 6), datetime.date(2026, 6, 7),
                               {0: 7.5, 1: 7.5, 2: 7.5, 3: 7.5, 4: 7.5})
        self.assertEqual(days, [])


class TestBuildPayload(unittest.TestCase):
    def test_basic(self):
        p = tr._build_worklog_payload(datetime.date(2026, 6, 8), 7.5, 12345, "work")
        self.assertEqual(p["timeStamp"], "2026-06-08T08:00:00")
        self.assertEqual(p["length"], 27000)
        self.assertEqual(p["workItemId"], 12345)
        self.assertEqual(p["comment"], "work")
        self.assertNotIn("billableLength", p)

    def test_optional_fields(self):
        p = tr._build_worklog_payload(datetime.date(2026, 6, 8), 1, 1, "c",
                                      activity_type_id="abc", billable_hours=0.5)
        self.assertEqual(p["billableLength"], 1800)
        self.assertEqual(p["activityTypeId"], "abc")


class TestConfigAuth(unittest.TestCase):
    def test_bearer(self):
        self.assertEqual(tr.get_auth_from_config({"auth": {"type": "bearer", "token": "T"}}),
                         ("bearer", "T", None))

    def test_pat_maps_to_bearer(self):
        self.assertEqual(tr.get_auth_from_config({"auth": {"type": "pat", "pat": "P"}}),
                         ("bearer", "P", None))

    def test_basic(self):
        self.assertEqual(
            tr.get_auth_from_config({"auth": {"type": "basic", "username": "u", "password": "p"}}),
            ("basic", "u", "p"))

    def test_empty_defaults_bearer(self):
        self.assertEqual(tr.get_auth_from_config({})[0], "bearer")


class TestClientUrlAndHeaders(unittest.TestCase):
    def test_url_and_bearer_header(self):
        c = tr.SevenPaceClient("https://x.timehub.7pace.com/", api_version="3.2", token="TOK")
        self.assertEqual(c._url("/api/rest/me"),
                         "https://x.timehub.7pace.com/api/rest/me?api-version=3.2")
        self.assertEqual(c.headers["Authorization"], "Bearer TOK")
        self.assertIsNone(c.auth)

    def test_basic_auth_no_bearer(self):
        c = tr.SevenPaceClient("https://x", token=None, username="u", password="p")
        self.assertEqual(c.auth, ("u", "p"))
        self.assertNotIn("Authorization", c.headers)

    def test_requires_some_auth(self):
        with self.assertRaises(ValueError):
            tr.SevenPaceClient("https://x")


class TestAuthSetup(unittest.TestCase):
    def test_writes_config_from_prompts(self):
        import tempfile
        # reader answers in order: account, org, project(Enter), work item, comment
        answers = iter(["acme", "Acme", "", "12345", "Work"])
        secrets = iter(["TOK7PACE", "ADOPAT"])
        with tempfile.TemporaryDirectory() as d:
            cfgp = Path(d) / "config.json"
            tr.run_auth_setup(cfgp, reader=lambda _p: next(answers),
                              secret_reader=lambda _p: next(secrets))
            cfg = json.loads(cfgp.read_text(encoding="utf-8"))
        self.assertEqual(cfg["auth"], {"type": "bearer", "token": "TOK7PACE"})
        self.assertEqual(cfg["base_url"], "https://acme.timehub.7pace.com")
        self.assertEqual(cfg["azure_devops"]["organization"], "Acme")
        self.assertEqual(cfg["azure_devops"]["pat"], "ADOPAT")
        self.assertIsNone(cfg["azure_devops"]["project"])
        self.assertEqual(cfg["defaults"]["work_item_id"], 12345)
        self.assertEqual(cfg["defaults"]["comment"], "Work")

    def test_full_url_and_skip_pat(self):
        import tempfile
        answers = iter(["", "https://acme.timehub.7pace.com", "Acme", "", "", "Work"])
        secrets = iter(["T", ""])
        with tempfile.TemporaryDirectory() as d:
            cfgp = Path(d) / "config.json"
            tr.run_auth_setup(cfgp, reader=lambda _p: next(answers),
                              secret_reader=lambda _p: next(secrets))
            cfg = json.loads(cfgp.read_text(encoding="utf-8"))
        self.assertEqual(cfg["base_url"], "https://acme.timehub.7pace.com")
        self.assertNotIn("pat", cfg["azure_devops"])
        self.assertNotIn("work_item_id", cfg["defaults"])


# ===========================================================================
# INTEGRATION TESTS (live API) - gated behind RUN_INTEGRATION=1
# ===========================================================================

def _config():
    if not CONFIG_PATH.exists():
        return {}
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


def _has_7pace_token(cfg):
    tok = (cfg.get("auth") or {}).get("token") or ""
    return bool(tok) and "PASTE" not in tok


def _has_azdo_pat(cfg):
    pat = (cfg.get("azure_devops") or {}).get("pat") or ""
    return bool(pat) and "PASTE" not in pat


_RUN = os.environ.get("RUN_INTEGRATION") == "1"
_CFG = _config()

# Tenant-specific test inputs come from env vars (or config) — never hardcoded:
#   SEVENPACE_TEST_WORK_ITEM  work item to create test worklogs on (or defaults.work_item_id)
#   AZDO_TEST_SEARCH_QUERY    a query that matches at least one work item in your org
#   AZDO_TEST_KNOWN_ID        a work item id expected among those matches
#   AZDO_TEST_PROJECT         an ADO project containing the matches (for scope tests)
TEST_WORK_ITEM = int(os.environ.get("SEVENPACE_TEST_WORK_ITEM")
                     or (_CFG.get("defaults") or {}).get("work_item_id") or 0)
_SEARCH_QUERY = os.environ.get("AZDO_TEST_SEARCH_QUERY")
_SEARCH_KNOWN_ID = int(os.environ.get("AZDO_TEST_KNOWN_ID") or 0)
_SEARCH_PROJECT = os.environ.get("AZDO_TEST_PROJECT")


@unittest.skipUnless(_RUN and _has_7pace_token(_CFG) and TEST_WORK_ITEM,
                     "needs RUN_INTEGRATION=1, a valid 7pace token, and SEVENPACE_TEST_WORK_ITEM "
                     "(or defaults.work_item_id in config.json)")
class TestWorklogIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.client = tr.SevenPaceClient(
            base_url=_CFG["base_url"], api_version=_CFG.get("api_version", "3.2"),
            token=_CFG["auth"]["token"])

    def _cleanup(self):
        for wl in self.client.get_worklogs(TEST_DATE, TEST_DATE):
            self.client.delete_worklog(wl["id"])

    def setUp(self):
        self._cleanup()

    def tearDown(self):
        self._cleanup()

    def test_auth_me(self):
        self.assertIn("data", self.client.get_me())

    def test_create_list_update_delete(self):
        self.client.create_worklog(TEST_DATE, 1.0, TEST_WORK_ITEM, MARKER)
        wls = self.client.get_worklogs(TEST_DATE, TEST_DATE)
        mine = [w for w in wls if w.get("comment") == MARKER]
        self.assertEqual(len(mine), 1)
        wid = mine[0]["id"]
        self.assertEqual(mine[0]["length"], 3600)
        ts = mine[0].get("timestamp") or mine[0].get("timeStamp")
        self.assertTrue(str(ts).startswith("2031-12-31"))
        self.client.update_worklog(wid, length=7200, comment=MARKER + " upd")
        self.assertEqual(self.client.get_worklogs(TEST_DATE, TEST_DATE)[0]["length"], 7200)
        res = self.client.delete_worklog(wid)
        self.assertEqual(res.get("status"), "deleted")
        self.assertEqual(len(self.client.get_worklogs(TEST_DATE, TEST_DATE)), 0)


@unittest.skipUnless(_RUN and _has_azdo_pat(_CFG) and (_CFG.get("azure_devops") or {}).get("organization"),
                     "needs RUN_INTEGRATION=1, a valid ADO PAT, and azure_devops.organization in config.json")
class TestSearchIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        azdo = _CFG["azure_devops"]
        cls.pat = azdo["pat"]
        cls.org = azdo["organization"]

    @unittest.skipUnless(_SEARCH_QUERY and _SEARCH_KNOWN_ID,
                         "needs AZDO_TEST_SEARCH_QUERY and AZDO_TEST_KNOWN_ID")
    def test_orgwide_finds_known(self):
        res = tr.azdo_search_work_items(_SEARCH_QUERY, self.pat, self.org, None)
        self.assertIn(_SEARCH_KNOWN_ID, [m["id"] for m in res])
        self.assertTrue(all({"id", "title", "project", "state"} <= set(m) for m in res))

    @unittest.skipUnless(_SEARCH_QUERY and _SEARCH_PROJECT,
                         "needs AZDO_TEST_SEARCH_QUERY and AZDO_TEST_PROJECT")
    def test_project_scope_narrows(self):
        res = tr.azdo_search_work_items(_SEARCH_QUERY, self.pat, self.org, _SEARCH_PROJECT)
        self.assertTrue(res)
        self.assertTrue(all(m["project"] == _SEARCH_PROJECT for m in res))

    def test_zero_matches(self):
        self.assertEqual(tr.azdo_search_work_items("zzz-nonexistent-xyzqwerty", self.pat, self.org, None), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
