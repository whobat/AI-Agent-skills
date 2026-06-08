#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Tests for tidsregistrering.py

Kør unit-tests (ingen netværk):
    python -m unittest test_tidsregistrering -v

Kør ALT inkl. integration mod den rigtige 7pace/ADO API (kræver gyldig config.json):
    RUN_INTEGRATION=1 python -m unittest test_tidsregistrering -v
    (Windows PowerShell:  $env:RUN_INTEGRATION=1; python -m unittest test_tidsregistrering -v)

Integrationstests opretter/sletter KUN på en sikker fremtidig testdato (2031-12-31)
og rydder op efter sig.
"""

import datetime
import json
import os
import unittest
from pathlib import Path

import tidsregistrering as tr

CONFIG_PATH = Path(__file__).with_name("config.json")
TEST_DATE = datetime.date(2031, 12, 31)   # langt ude i fremtiden -> kolliderer ikke med rigtige data
TEST_WORK_ITEM = 32933                     # IT Infrastruktur - Generel DGFS
MARKER = "UNITTEST – maa slettes"


# ===========================================================================
# UNIT TESTS (ingen netværk)
# ===========================================================================

class TestParseDanishDate(unittest.TestCase):
    def test_iso(self):
        self.assertEqual(tr.parse_danish_date("2026-06-08"), datetime.date(2026, 6, 8))

    def test_dk_formats(self):
        self.assertEqual(tr.parse_danish_date("08-06-2026"), datetime.date(2026, 6, 8))
        self.assertEqual(tr.parse_danish_date("08/06/2026"), datetime.date(2026, 6, 8))

    def test_today_aliases(self):
        today = datetime.date.today()
        for alias in ("dags dato", "idag", "i dag", "DAGS DATO"):
            self.assertEqual(tr.parse_danish_date(alias), today)

    def test_month_name(self):
        d = tr.parse_danish_date("april")
        self.assertEqual((d.month, d.day), (4, 1))

    def test_invalid(self):
        with self.assertRaises(ValueError):
            tr.parse_danish_date("ikke en dato")


class TestParseWeekdayHours(unittest.TestCase):
    def test_alle(self):
        self.assertEqual(tr.parse_weekday_hours("alle"), {0: 7.5, 1: 7.5, 2: 7.5, 3: 7.5, 4: 7.5})

    def test_range_and_single(self):
        self.assertEqual(tr.parse_weekday_hours("7.5 man-tor og 7.0 fre"),
                         {0: 7.5, 1: 7.5, 2: 7.5, 3: 7.5, 4: 7.0})

    def test_colon_and_comma_numbers(self):
        # 7:30 -> 7.30? Nej: scriptet erstatter ':' med '.', så 7:30 => 7.30. HH:MM håndteres af CLI andetsteds.
        self.assertEqual(tr.parse_weekday_hours("7,5 mandag,onsdag"), {0: 7.5, 2: 7.5})

    def test_invalid_weekday(self):
        with self.assertRaises(ValueError):
            tr.parse_weekday_hours("7.5 xyzdag")


class TestGetWeekdays(unittest.TestCase):
    def test_skips_weekend(self):
        # uge: man 2026-06-01 ... søn 2026-06-07
        wh = {0: 7.5, 1: 7.5, 2: 7.5, 3: 7.5, 4: 7.0}
        days = tr.get_weekdays(datetime.date(2026, 6, 1), datetime.date(2026, 6, 7), wh)
        self.assertEqual(len(days), 5)
        weekdays = {d.weekday() for d, _ in days}
        self.assertNotIn(5, weekdays)  # lør
        self.assertNotIn(6, weekdays)  # søn
        self.assertEqual(days[-1][1], 7.0)  # fredag = 7.0

    def test_empty_range(self):
        # kun en weekend
        days = tr.get_weekdays(datetime.date(2026, 6, 6), datetime.date(2026, 6, 7),
                               {0: 7.5, 1: 7.5, 2: 7.5, 3: 7.5, 4: 7.5})
        self.assertEqual(days, [])


class TestBuildPayload(unittest.TestCase):
    def test_basic(self):
        p = tr._build_worklog_payload(datetime.date(2026, 6, 8), 7.5, 32933, "arbejde")
        self.assertEqual(p["timeStamp"], "2026-06-08T08:00:00")
        self.assertEqual(p["length"], 27000)        # 7.5 * 3600
        self.assertEqual(p["workItemId"], 32933)
        self.assertEqual(p["comment"], "arbejde")
        self.assertNotIn("billableLength", p)
        self.assertNotIn("activityTypeId", p)

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
        # gammelt "pat"-felt skal nu behandles som bearer-token
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
        # reader-svar i kaldsrækkefølge: konto, org, projekt(Enter), work item, kommentar
        answers = iter(["dagrofa", "Dagrofa", "", "32933", "Arbejde"])
        secrets = iter(["TOK7PACE", "ADOPAT"])  # 7pace-token, ADO-pat
        with tempfile.TemporaryDirectory() as d:
            cfgp = Path(d) / "config.json"
            tr.run_auth_setup(cfgp, reader=lambda _p: next(answers),
                              secret_reader=lambda _p: next(secrets))
            cfg = json.loads(cfgp.read_text(encoding="utf-8"))
        self.assertEqual(cfg["auth"], {"type": "bearer", "token": "TOK7PACE"})
        self.assertEqual(cfg["base_url"], "https://dagrofa.timehub.7pace.com")
        self.assertEqual(cfg["azure_devops"]["organization"], "Dagrofa")
        self.assertEqual(cfg["azure_devops"]["pat"], "ADOPAT")
        self.assertIsNone(cfg["azure_devops"]["project"])
        self.assertEqual(cfg["defaults"]["work_item_id"], 32933)
        self.assertEqual(cfg["defaults"]["comment"], "Arbejde")

    def test_full_url_and_skip_pat(self):
        import tempfile
        answers = iter(["", "https://acme.timehub.7pace.com", "Acme", "", "", "Work"])
        secrets = iter(["T", ""])  # token, ingen ADO-pat
        with tempfile.TemporaryDirectory() as d:
            cfgp = Path(d) / "config.json"
            tr.run_auth_setup(cfgp, reader=lambda _p: next(answers),
                              secret_reader=lambda _p: next(secrets))
            cfg = json.loads(cfgp.read_text(encoding="utf-8"))
        self.assertEqual(cfg["base_url"], "https://acme.timehub.7pace.com")
        self.assertNotIn("pat", cfg["azure_devops"])           # sprunget over
        self.assertNotIn("work_item_id", cfg["defaults"])      # ikke angivet


# ===========================================================================
# INTEGRATION TESTS (rigtig API) — gated bag RUN_INTEGRATION=1
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


@unittest.skipUnless(_RUN and _has_7pace_token(_CFG), "kræver RUN_INTEGRATION=1 og gyldigt 7pace-token")
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
        me = self.client.get_me()
        self.assertIn("data", me)

    def test_create_list_update_delete(self):
        # CREATE
        self.client.create_worklog(TEST_DATE, 1.0, TEST_WORK_ITEM, MARKER)
        wls = self.client.get_worklogs(TEST_DATE, TEST_DATE)
        mine = [w for w in wls if w.get("comment") == MARKER]
        self.assertEqual(len(mine), 1, "præcis én oprettet entry forventet")
        wid = mine[0]["id"]
        self.assertEqual(mine[0]["length"], 3600)               # 1 time
        # timestamp-nøglen (lowercase) skal kunne læses (skip-existing bug-fix)
        ts = mine[0].get("timestamp") or mine[0].get("timeStamp")
        self.assertTrue(str(ts).startswith("2031-12-31"))
        # UPDATE
        self.client.update_worklog(wid, length=7200, comment=MARKER + " upd")
        upd = self.client.get_worklogs(TEST_DATE, TEST_DATE)[0]
        self.assertEqual(upd["length"], 7200)                   # 2 timer
        # DELETE (tom 204-body må ikke crashe)
        res = self.client.delete_worklog(wid)
        self.assertEqual(res.get("status"), "deleted")
        self.assertEqual(len(self.client.get_worklogs(TEST_DATE, TEST_DATE)), 0)


@unittest.skipUnless(_RUN and _has_azdo_pat(_CFG), "kræver RUN_INTEGRATION=1 og gyldigt ADO PAT")
class TestSearchIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        azdo = _CFG["azure_devops"]
        cls.pat = azdo["pat"]
        cls.org = azdo.get("organization", "Dagrofa")

    def test_orgwide_finds_known(self):
        res = tr.azdo_search_work_items("Generel", self.pat, self.org, None)
        self.assertIn(32933, [m["id"] for m in res])
        # output-felter til disambiguering
        self.assertTrue(all({"id", "title", "project", "state"} <= set(m) for m in res))

    def test_orgwide_finds_cross_project(self):
        # #840 ligger i projektet "Administration" -> kun org-bred finder den
        res = tr.azdo_search_work_items("Ikke-arbejdstid", self.pat, self.org, None)
        self.assertIn(840, [m["id"] for m in res])

    def test_project_scope_narrows(self):
        res = tr.azdo_search_work_items("Generel", self.pat, self.org, "IT Infrastruktur")
        self.assertTrue(res)
        self.assertTrue(all(m["project"] == "IT Infrastruktur" for m in res))

    def test_project_scope_excludes_other_project(self):
        res = tr.azdo_search_work_items("Ikke-arbejdstid", self.pat, self.org, "IT Infrastruktur")
        self.assertEqual(res, [])

    def test_zero_matches(self):
        res = tr.azdo_search_work_items("zzz-findes-ikke-xyzqwerty", self.pat, self.org, None)
        self.assertEqual(res, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
