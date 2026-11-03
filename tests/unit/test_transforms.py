"""Spark transformations, run on a local SparkSession."""

from __future__ import annotations

import json
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

from pyspark.sql import DataFrame, Row, SparkSession

from orders_incremental import (
    ORDERS_COLUMNS,
    RAW_ORDERS_SCHEMA,
    dedupe_latest,
    partition_paths,
    read_raw_orders,
    standardise_orders,
)


def raw_rows(spark: SparkSession, rows: list[dict[str, str | None]], ingest_date: str) -> DataFrame:
    """Build a raw DataFrame the way the reader does: raw schema + ingest_date."""
    df = spark.createDataFrame([Row(**r) for r in rows], schema=RAW_ORDERS_SCHEMA)
    return df.selectExpr("*", f"DATE'{ingest_date}' AS ingest_date")


def order(
    order_id: str | None, updated_at: str | None, status: str = "paid", total: str = "10.00"
) -> dict[str, str | None]:
    return {
        "order_id": order_id,
        "customer_id": " cust-001 ",
        "status": status,
        "total_amount": total,
        "currency": "eur",
        "order_ts": "2026-03-01T08:00:00Z",
        "updated_at": updated_at,
    }


class TestStandardiseOrders:
    def test_output_matches_target_schema(self, spark: SparkSession) -> None:
        df = standardise_orders(
            raw_rows(spark, [order("o-1", "2026-03-01T09:00:00Z")], "2026-03-01")
        )
        assert [(f.name, f.dataType.simpleString()) for f in df.schema.fields] == list(
            ORDERS_COLUMNS
        )

    def test_trims_cases_and_casts(self, spark: SparkSession) -> None:
        row = standardise_orders(
            raw_rows(
                spark,
                [order(" o-1 ", "2026-03-01T09:00:00Z", status=" PAID ", total="12.5")],
                "2026-03-01",
            )
        ).first()
        assert row is not None
        assert row["order_id"] == "o-1"
        assert row["customer_id"] == "cust-001"
        assert row["order_status"] == "paid"
        assert row["currency"] == "EUR"
        assert row["order_total"] == Decimal("12.50")
        assert row["updated_at"] == datetime(2026, 3, 1, 9, 0)
        assert row["ingest_date"] == date(2026, 3, 1)

    def test_drops_rows_without_business_key(self, spark: SparkSession) -> None:
        rows = [
            order(None, "2026-03-01T09:00:00Z"),
            order("  ", "2026-03-01T09:00:00Z"),
            order("o-2", "2026-03-01T09:00:00Z"),
        ]
        result = standardise_orders(raw_rows(spark, rows, "2026-03-01"))
        assert [r["order_id"] for r in result.collect()] == ["o-2"]

    def test_keeps_bad_amounts_visible_as_null(self, spark: SparkSession) -> None:
        # Not filtered here on purpose: the Athena DQ query should see them.
        row = standardise_orders(
            raw_rows(
                spark, [order("o-3", "2026-03-01T09:00:00Z", total="not-a-number")], "2026-03-01"
            )
        ).first()
        assert row is not None and row["order_total"] is None


class TestDedupeLatest:
    def test_keeps_newest_version_per_key(self, spark: SparkSession) -> None:
        rows = [
            order("o-1", "2026-03-01T09:00:00Z", status="placed"),
            order("o-1", "2026-03-01T11:00:00Z", status="shipped"),
            order("o-1", "2026-03-01T10:00:00Z", status="paid"),
            order("o-2", "2026-03-01T09:00:00Z", status="placed"),
        ]
        result = dedupe_latest(standardise_orders(raw_rows(spark, rows, "2026-03-01")))
        assert sorted((r["order_id"], r["order_status"]) for r in result.collect()) == [
            ("o-1", "shipped"),
            ("o-2", "placed"),
        ]

    def test_tie_on_version_prefers_later_partition(self, spark: SparkSession) -> None:
        early = raw_rows(
            spark, [order("o-1", "2026-03-01T09:00:00Z", status="placed")], "2026-03-01"
        )
        late = raw_rows(spark, [order("o-1", "2026-03-01T09:00:00Z", status="paid")], "2026-03-02")
        result = dedupe_latest(standardise_orders(early.unionByName(late))).collect()
        assert [(r["order_status"], r["ingest_date"]) for r in result] == [
            ("paid", date(2026, 3, 2))
        ]

    def test_null_versions_lose(self, spark: SparkSession) -> None:
        rows = [
            order("o-1", None, status="placed"),
            order("o-1", "2026-03-01T09:00:00Z", status="paid"),
        ]
        result = dedupe_latest(standardise_orders(raw_rows(spark, rows, "2026-03-01"))).collect()
        assert [r["order_status"] for r in result] == ["paid"]


def test_read_raw_orders_end_to_end(spark: SparkSession, tmp_path: Path) -> None:
    """Partition layout on disk -> reader -> standardise -> dedupe, as main() does."""
    days = {
        "2026-03-01": [order("o-1", "2026-03-01T09:00:00Z", status="placed")],
        "2026-03-02": [
            order("o-1", "2026-03-02T09:00:00Z", status="shipped"),
            order("o-2", "2026-03-02T10:00:00Z"),
        ],
        "2026-03-03": [order("o-3", "2026-03-03T10:00:00Z")],  # not selected below
    }
    base = tmp_path / "orders"
    for day, rows in days.items():
        part = base / f"ingest_date={day}"
        part.mkdir(parents=True)
        (part / "part-0000.json").write_text("\n".join(json.dumps(r) for r in rows))

    selected = [date(2026, 3, 1), date(2026, 3, 2)]
    # partition_paths builds s3:// URIs; with an absolute local "bucket" path
    # swapping the scheme gives file:///<tmp>/orders/ingest_date=.../
    paths = [
        p.replace("s3://", "file://") for p in partition_paths(str(tmp_path), "orders", selected)
    ]

    batch = dedupe_latest(standardise_orders(read_raw_orders(spark, f"file://{base}/", paths)))
    assert sorted(
        (r["order_id"], r["order_status"], r["ingest_date"]) for r in batch.collect()
    ) == [
        ("o-1", "shipped", date(2026, 3, 2)),
        ("o-2", "paid", date(2026, 3, 2)),
    ]
