"""Incrementally merge raw order extracts into an Apache Iceberg table.

Raw layout (written by an upstream extract, JSON lines):

    s3://<raw_bucket>/<raw_prefix>/ingest_date=YYYY-MM-DD/part-*.json

Each run:
  1. reads the high-water mark (max ingest_date) from the target table,
  2. lists raw partitions and keeps those at or after the mark minus a
     lookback window (late files land in "old" partitions),
  3. normalises types, drops rows without a business key and keeps only the
     newest version of each order inside the batch,
  4. MERGEs the batch into the Iceberg table on order_id, updating a row only
     when the incoming version is newer.

Steps 2-4 are pure functions so they can be unit-tested with local PySpark;
`main()` is the thin Glue entrypoint that wires them to S3 and the catalog.
Re-running a day is safe: the MERGE is idempotent for identical input.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Sequence
from datetime import date, timedelta

from pyspark.sql import DataFrame, SparkSession, Window
from pyspark.sql import functions as F
from pyspark.sql import types as T

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

#: Target table columns in order, as (name, Spark SQL type). Kept in sync with
#: the Glue catalog definition in examples/dev/main.tf by a unit test.
ORDERS_COLUMNS: tuple[tuple[str, str], ...] = (
    ("order_id", "string"),
    ("customer_id", "string"),
    ("order_status", "string"),
    ("order_total", "decimal(12,2)"),
    ("currency", "string"),
    ("order_ts", "timestamp"),
    ("updated_at", "timestamp"),
    ("ingest_date", "date"),
)

BUSINESS_KEY: tuple[str, ...] = ("order_id",)
VERSION_COLUMN = "updated_at"
PARTITION_COLUMN = "ingest_date"

#: Schema of the raw JSON. Reading with an explicit schema avoids a full
#: inference pass over the input and stops a single malformed file from
#: silently changing column types. Amounts arrive as strings to keep their
#: exact decimal value.
RAW_ORDERS_SCHEMA = T.StructType(
    [
        T.StructField("order_id", T.StringType()),
        T.StructField("customer_id", T.StringType()),
        T.StructField("status", T.StringType()),
        T.StructField("total_amount", T.StringType()),
        T.StructField("currency", T.StringType()),
        T.StructField("order_ts", T.StringType()),
        T.StructField("updated_at", T.StringType()),
    ]
)

_PARTITION_RE = re.compile(rf"{PARTITION_COLUMN}=(\d{{4}}-\d{{2}}-\d{{2}})/?$")
_IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


# ---------------------------------------------------------------------------
# Partition selection (pure Python)
# ---------------------------------------------------------------------------


def parse_partition_dates(prefixes: Iterable[str]) -> list[date]:
    """Extract partition dates from S3 "directory" prefixes.

    Prefixes that are not `ingest_date=YYYY-MM-DD` (for example `_tmp/` from a
    half-finished upstream copy) or carry an impossible date are ignored rather
    than failing the run.
    """
    found: set[date] = set()
    for prefix in prefixes:
        match = _PARTITION_RE.search(prefix)
        if not match:
            continue
        try:
            found.add(date.fromisoformat(match.group(1)))
        except ValueError:
            continue
    return sorted(found)


def select_new_partitions(
    available: Iterable[date],
    watermark: date | None,
    lookback_days: int = 0,
) -> list[date]:
    """Choose which raw partitions this run should read.

    * No watermark (empty target table): everything, i.e. the initial load.
    * Otherwise: partitions on or after `watermark - lookback_days`. The
      watermark day itself is always re-read because it may have been only
      partly landed when the previous run looked at it.
    """
    if lookback_days < 0:
        raise ValueError("lookback_days must be >= 0")
    partitions = sorted(set(available))
    if watermark is None:
        return partitions
    start = watermark - timedelta(days=lookback_days)
    return [d for d in partitions if d >= start]


def partition_paths(bucket: str, prefix: str, dates: Sequence[date]) -> list[str]:
    """Build the S3 URIs for the selected partitions."""
    base = f"s3://{bucket}/{prefix.strip('/')}"
    return [f"{base}/{PARTITION_COLUMN}={d.isoformat()}/" for d in dates]


# ---------------------------------------------------------------------------
# Transformations (pure PySpark)
# ---------------------------------------------------------------------------


def standardise_orders(raw: DataFrame) -> DataFrame:
    """Rename, trim and cast raw columns to the target schema.

    Rows without a business key are dropped here: they can never be merged
    (the ON clause would not match anything) and would be inserted as
    unaddressable duplicates. Other quality rules are *checked* downstream by
    the Athena query rather than silently filtered, so problems stay visible.

    Casts use SQL `try_cast`, which yields NULL for malformed input on every
    Spark version. A plain cast would behave differently on Glue 4/5 (Spark
    3.x, ANSI off: NULL) and Spark 4 (ANSI on by default: the job fails).
    """
    order_id = F.trim(F.col("order_id"))
    return raw.select(
        order_id.alias("order_id"),
        F.trim(F.col("customer_id")).alias("customer_id"),
        F.lower(F.trim(F.col("status"))).alias("order_status"),
        F.expr("try_cast(trim(total_amount) AS decimal(12,2))").alias("order_total"),
        F.upper(F.trim(F.col("currency"))).alias("currency"),
        F.expr("try_cast(order_ts AS timestamp)").alias("order_ts"),
        F.expr("try_cast(updated_at AS timestamp)").alias("updated_at"),
        F.col(PARTITION_COLUMN).cast("date").alias(PARTITION_COLUMN),
    ).where(F.col("order_id").isNotNull() & (F.col("order_id") != ""))


def dedupe_latest(
    df: DataFrame,
    key_columns: Sequence[str] = BUSINESS_KEY,
    version_column: str = VERSION_COLUMN,
    tiebreak_column: str = PARTITION_COLUMN,
) -> DataFrame:
    """Keep one row per business key: the newest by `version_column`.

    MERGE INTO fails if several source rows match the same target row, so the
    batch must be unique on the key. Ties on the version are broken by the
    later partition so the result is deterministic across runs.
    """
    if not key_columns:
        raise ValueError("key_columns must not be empty")
    window = Window.partitionBy(*key_columns).orderBy(
        F.col(version_column).desc_nulls_last(),
        F.col(tiebreak_column).desc_nulls_last(),
    )
    return (
        df.withColumn("_row_number", F.row_number().over(window))
        .where(F.col("_row_number") == 1)
        .drop("_row_number")
    )


# ---------------------------------------------------------------------------
# SQL builder (pure Python)
# ---------------------------------------------------------------------------


def _check_identifier(name: str) -> str:
    # Identifiers are interpolated into SQL, so only plain names are allowed.
    if not _IDENTIFIER_RE.fullmatch(name):
        raise ValueError(f"unsafe SQL identifier: {name!r}")
    return name


def _check_table_name(name: str) -> str:
    parts = name.split(".")
    if not 1 <= len(parts) <= 3:
        raise ValueError(f"table name must have 1-3 parts: {name!r}")
    for part in parts:
        _check_identifier(part)
    return name


def build_merge_sql(
    target_table: str,
    source_view: str,
    columns: Sequence[str],
    key_columns: Sequence[str] = BUSINESS_KEY,
    version_column: str | None = VERSION_COLUMN,
) -> str:
    """Return an Iceberg `MERGE INTO` statement for an upsert on the key.

    With `version_column` set, a matched row is only updated when the source
    version is strictly newer. That makes replays of old partitions (lookback,
    manual backfills) harmless: they can never overwrite fresher data.
    """
    _check_table_name(target_table)
    _check_identifier(source_view)
    cols = [_check_identifier(c) for c in columns]
    keys = [_check_identifier(k) for k in key_columns]
    if not keys:
        raise ValueError("key_columns must not be empty")
    if len(set(cols)) != len(cols):
        raise ValueError("columns contains duplicates")
    missing = [k for k in keys if k not in cols]
    if missing:
        raise ValueError(f"key columns not in columns: {missing}")
    if version_column is not None and _check_identifier(version_column) not in cols:
        raise ValueError(f"version column {version_column!r} not in columns")

    on_clause = " AND ".join(f"t.{k} = s.{k}" for k in keys)
    update_cols = [c for c in cols if c not in keys]
    matched_condition = f" AND s.{version_column} > t.{version_column}" if version_column else ""
    set_clause = ",\n    ".join(f"t.{c} = s.{c}" for c in update_cols)
    insert_cols = ", ".join(cols)
    insert_vals = ", ".join(f"s.{c}" for c in cols)

    lines = [
        f"MERGE INTO {target_table} AS t",
        f"USING {source_view} AS s",
        f"ON {on_clause}",
    ]
    if update_cols:
        lines.append(f"WHEN MATCHED{matched_condition} THEN UPDATE SET\n    {set_clause}")
    lines.append(f"WHEN NOT MATCHED THEN INSERT ({insert_cols})\nVALUES ({insert_vals})")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# I/O helpers used by the entrypoint
# ---------------------------------------------------------------------------


def read_watermark(spark: SparkSession, target_table: str) -> date | None:
    """Return the newest ingest_date already merged, or None for an empty table."""
    _check_table_name(target_table)
    row = spark.sql(f"SELECT max({PARTITION_COLUMN}) AS wm FROM {target_table}").first()
    return row["wm"] if row is not None else None


def read_raw_orders(spark: SparkSession, base_path: str, paths: Sequence[str]) -> DataFrame:
    """Read the selected raw partitions with the fixed raw schema.

    `basePath` makes Spark keep `ingest_date` as a column even though only
    individual partition directories are passed in.
    """
    return spark.read.schema(RAW_ORDERS_SCHEMA).option("basePath", base_path).json(list(paths))


def list_raw_partition_prefixes(s3_client: object, bucket: str, prefix: str) -> list[str]:
    """List the immediate "sub-directories" of `prefix` in S3."""
    paginator = s3_client.get_paginator("list_objects_v2")  # type: ignore[attr-defined]
    prefixes: list[str] = []
    for page in paginator.paginate(Bucket=bucket, Prefix=f"{prefix.strip('/')}/", Delimiter="/"):
        prefixes.extend(p["Prefix"] for p in page.get("CommonPrefixes", []))
    return prefixes


def main() -> None:  # pragma: no cover - needs the Glue runtime
    """Glue entrypoint. Kept deliberately thin; logic lives in the functions above."""
    import sys

    import boto3
    from awsglue.context import GlueContext
    from awsglue.job import Job
    from awsglue.utils import getResolvedOptions
    from pyspark.context import SparkContext

    args = getResolvedOptions(
        sys.argv, ["JOB_NAME", "raw_bucket", "raw_prefix", "target_table", "lookback_days"]
    )
    glue_context = GlueContext(SparkContext.getOrCreate())
    spark = glue_context.spark_session
    logger = glue_context.get_logger()
    job = Job(glue_context)
    job.init(args["JOB_NAME"], args)

    watermark = read_watermark(spark, args["target_table"])
    available = parse_partition_dates(
        list_raw_partition_prefixes(boto3.client("s3"), args["raw_bucket"], args["raw_prefix"])
    )
    selected = select_new_partitions(available, watermark, int(args["lookback_days"]))
    logger.info(f"watermark={watermark} available={len(available)} selected={selected}")

    if not selected:
        logger.info("No new partitions; nothing to merge.")
        job.commit()
        return

    base_path = f"s3://{args['raw_bucket']}/{args['raw_prefix'].strip('/')}/"
    raw = read_raw_orders(
        spark, base_path, partition_paths(args["raw_bucket"], args["raw_prefix"], selected)
    )
    batch = dedupe_latest(standardise_orders(raw))
    batch.createOrReplaceTempView("orders_batch")

    spark.sql(
        build_merge_sql(
            target_table=args["target_table"],
            source_view="orders_batch",
            columns=[name for name, _ in ORDERS_COLUMNS],
        )
    )
    job.commit()


if __name__ == "__main__":  # pragma: no cover
    main()
