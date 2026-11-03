"""Guard against drift between the job's schema and the Terraform table definition.

The Glue catalog table is declared in examples/dev/main.tf; the job writes
ORDERS_COLUMNS. If someone changes one without the other, the MERGE fails at
run time in AWS. This test catches it in CI instead.
"""

from __future__ import annotations

import re
from pathlib import Path

from orders_incremental import ORDERS_COLUMNS

EXAMPLE_MAIN = Path(__file__).resolve().parents[2] / "examples" / "dev" / "main.tf"
COLUMN_RE = re.compile(r'\{\s*name\s*=\s*"(?P<name>[^"]+)",\s*type\s*=\s*"(?P<type>[^"]+)"')


def terraform_columns() -> list[tuple[str, str]]:
    text = EXAMPLE_MAIN.read_text(encoding="utf-8")
    block = text.split("orders_columns = [", 1)[1].split("]\n", 1)[0]
    return [(m["name"], m["type"]) for m in COLUMN_RE.finditer(block)]


def test_terraform_table_matches_job_schema() -> None:
    assert terraform_columns() == list(ORDERS_COLUMNS)
