"""Shared fixtures: one small local SparkSession for the whole test run."""

from __future__ import annotations

import os
import time
from collections.abc import Iterator

import pytest
from pyspark.sql import SparkSession

# PySpark converts TIMESTAMP values to naive datetimes in the *Python process*
# time zone when collecting. Pin it (and the JVM's) to UTC so assertions do not
# depend on the machine running the tests.
os.environ["TZ"] = "UTC"
time.tzset()


@pytest.fixture(scope="session")
def spark() -> Iterator[SparkSession]:
    # local[1] + one shuffle partition keeps tests fast and output ordering
    # stable; the UI is disabled so parallel CI jobs never fight over a port.
    session = (
        SparkSession.builder.master("local[1]")
        .appName("orders-incremental-tests")
        .config("spark.sql.shuffle.partitions", "1")
        .config("spark.ui.enabled", "false")
        .config("spark.sql.session.timeZone", "UTC")
        .config("spark.driver.extraJavaOptions", "-Duser.timezone=UTC")
        .getOrCreate()
    )
    yield session
    session.stop()
