"""The MERGE INTO builder. Checked as text: the Iceberg runtime is not loaded
in these tests, so the statement is not executed (see README Limitations)."""

from __future__ import annotations

import re

import pytest

from orders_incremental import ORDERS_COLUMNS, build_merge_sql

COLUMNS = [name for name, _ in ORDERS_COLUMNS]


def normalise(sql: str) -> str:
    return re.sub(r"\s+", " ", sql).strip()


def test_full_statement_for_orders() -> None:
    sql = normalise(build_merge_sql("glue_catalog.sales.orders", "orders_batch", COLUMNS))
    assert sql == normalise(
        """
        MERGE INTO glue_catalog.sales.orders AS t
        USING orders_batch AS s
        ON t.order_id = s.order_id
        WHEN MATCHED AND s.updated_at > t.updated_at THEN UPDATE SET
            t.customer_id = s.customer_id,
            t.order_status = s.order_status,
            t.order_total = s.order_total,
            t.currency = s.currency,
            t.order_ts = s.order_ts,
            t.updated_at = s.updated_at,
            t.ingest_date = s.ingest_date
        WHEN NOT MATCHED THEN INSERT
            (order_id, customer_id, order_status, order_total, currency, order_ts, updated_at, ingest_date)
        VALUES
            (s.order_id, s.customer_id, s.order_status, s.order_total, s.currency, s.order_ts, s.updated_at, s.ingest_date)
        """
    )


def test_composite_key_and_no_version_guard() -> None:
    sql = normalise(
        build_merge_sql(
            "db.lines", "src", ["order_id", "line_no", "qty"], ["order_id", "line_no"], None
        )
    )
    assert "ON t.order_id = s.order_id AND t.line_no = s.line_no" in sql
    assert "WHEN MATCHED THEN UPDATE SET t.qty = s.qty" in sql


def test_key_only_table_has_no_update_branch() -> None:
    sql = build_merge_sql("db.keys", "src", ["id"], ["id"], None)
    assert "WHEN MATCHED" not in sql
    assert "WHEN NOT MATCHED THEN INSERT (id)" in sql


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"target_table": "db.orders; DROP TABLE x"}, "unsafe"),
        ({"target_table": "a.b.c.d"}, "1-3 parts"),
        ({"source_view": "batch-view"}, "unsafe"),
        ({"columns": ["order_id", "order id"]}, "unsafe"),
        ({"columns": ["order_id", "order_id", "updated_at"]}, "duplicates"),
        ({"key_columns": []}, "must not be empty"),
        ({"key_columns": ["missing"]}, "not in columns"),
        ({"version_column": "missing"}, "version column"),
    ],
)
def test_rejects_invalid_input(kwargs: dict[str, object], message: str) -> None:
    args: dict[str, object] = {
        "target_table": "glue_catalog.sales.orders",
        "source_view": "orders_batch",
        "columns": COLUMNS,
    }
    args.update(kwargs)
    with pytest.raises(ValueError, match=message):
        build_merge_sql(**args)  # type: ignore[arg-type]
