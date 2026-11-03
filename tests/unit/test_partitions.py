"""Partition discovery and selection: pure Python, no Spark needed."""

from __future__ import annotations

from datetime import date

import pytest

from orders_incremental import parse_partition_dates, partition_paths, select_new_partitions

D = date.fromisoformat


class TestParsePartitionDates:
    def test_extracts_sorted_unique_dates(self) -> None:
        prefixes = [
            "orders/ingest_date=2026-03-02/",
            "orders/ingest_date=2026-03-01/",
            "orders/ingest_date=2026-03-02",
        ]
        assert parse_partition_dates(prefixes) == [D("2026-03-01"), D("2026-03-02")]

    def test_ignores_non_partition_and_invalid_prefixes(self) -> None:
        prefixes = [
            "orders/_tmp/",
            "orders/ingest_date=2026-02-30/",  # impossible date
            "orders/ingest_date=latest/",
            "orders/ingest_date=2026-03-01/",
        ]
        assert parse_partition_dates(prefixes) == [D("2026-03-01")]

    def test_empty_input(self) -> None:
        assert parse_partition_dates([]) == []


class TestSelectNewPartitions:
    available = (D("2026-03-01"), D("2026-03-02"), D("2026-03-03"), D("2026-03-04"))

    def test_initial_load_takes_everything(self) -> None:
        assert select_new_partitions(self.available, watermark=None) == list(self.available)

    def test_rereads_watermark_day_without_lookback(self) -> None:
        # The watermark day may have been only partly landed last time.
        assert select_new_partitions(self.available, D("2026-03-03")) == [
            D("2026-03-03"),
            D("2026-03-04"),
        ]

    def test_lookback_reaches_further_back(self) -> None:
        assert select_new_partitions(self.available, D("2026-03-03"), lookback_days=1) == [
            D("2026-03-02"),
            D("2026-03-03"),
            D("2026-03-04"),
        ]

    def test_nothing_new(self) -> None:
        assert select_new_partitions([D("2026-03-01")], D("2026-03-05")) == []

    def test_deduplicates_and_sorts(self) -> None:
        unsorted = [D("2026-03-04"), D("2026-03-02"), D("2026-03-04")]
        assert select_new_partitions(unsorted, None) == [D("2026-03-02"), D("2026-03-04")]

    def test_rejects_negative_lookback(self) -> None:
        with pytest.raises(ValueError):
            select_new_partitions(self.available, D("2026-03-03"), lookback_days=-1)


def test_partition_paths_normalises_slashes() -> None:
    assert partition_paths("raw-bucket", "/orders/", [D("2026-03-01")]) == [
        "s3://raw-bucket/orders/ingest_date=2026-03-01/"
    ]
