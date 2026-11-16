"""Parsers for the two authoritative specification documents (read-only).

Used by the coverage test and by tools/schema_coverage.py so both compare the
live database against the SAME interpretation of the source documents.
"""
from __future__ import annotations

import re
import pathlib

REPO = pathlib.Path(__file__).resolve().parents[3]
IDENTITY_MD = REPO / "COP3_Identity_Consolidated_Schema_v1.md"
TENANT_MD = REPO / "COB3_Tenant_Schema_Summary_v1.md"


def _norm_type(t: str) -> str:
    t = t.strip().strip("`").strip()
    m = re.match(r"^varchar\((\d+)\)$", t)
    if m:
        return f"character varying({m.group(1)})"
    return {"timestamptz": "timestamp with time zone"}.get(t, t)


def parse_identity_spec() -> dict:
    text = IDENTITY_MD.read_text(encoding="utf-8")
    tables = {}
    for m in re.finditer(r"^### \d+\. `cop3_identity\.(\w+)`(.*?)(?=^### |\Z)", text, re.S | re.M):
        cols = {}
        for row in re.finditer(r"^\| `(\w+)` \| `([^`]+)` \| (NOT NULL|NULL)", m.group(2), re.M):
            cols[row.group(1)] = (_norm_type(row.group(2)), row.group(3) == "NOT NULL")
        tables[m.group(1)] = cols
    return tables


def parse_tenant_spec() -> dict:
    text = TENANT_MD.read_text(encoding="utf-8")
    scopes = {m.group(1): m.group(2) for m in re.finditer(
        r"^\| \d+ \| `(\w+)` \| (Tenant root|Tenant|Platform|Organization|Attributed) \|", text, re.M)}
    tables = {}
    for m in re.finditer(r"^### \d+\.\d+ `(\w+)`(.*?)(?=^### |^## |\Z)", text, re.S | re.M):
        name, body = m.group(1), m.group(2)
        cols = {}
        if name == "tenants":
            for row in re.finditer(r"^\| `(\w+)` \| `([^`]+)` \|", body, re.M):
                typ = row.group(2)
                cols[row.group(1)] = (_norm_type(typ.rstrip("?")), not typ.endswith("?"))
        else:
            para = re.search(r"Columns: (.*?)\n\n", body, re.S).group(1)
            for seg in re.findall(r"`([^`]+)`", para):
                parts = seg.split(None, 1)
                if len(parts) < 2:
                    continue
                tm = re.match(r"([a-z]+(?:\([0-9, ]+\))?)(\?)?", parts[1])
                cols[parts[0]] = (_norm_type(tm.group(1)), tm.group(2) is None)
        scope = scopes[name]
        cols.setdefault("tenant_id", ("uuid", scope != "Platform"))
        cols.setdefault("organization_id", ("uuid", scope == "Organization"))
        for c, t in (("created_at", "timestamp with time zone"), ("created_by", "character varying(255)"),
                     ("updated_at", "timestamp with time zone"), ("updated_by", "character varying(255)"),
                     ("metadata", "jsonb"), ("row_version", "bigint")):
            cols.setdefault(c, (t, True))
        tables[name] = cols
    return tables
