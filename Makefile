# Local entry points; CI (.github/workflows/ci.yml) runs the same targets.
# Nothing here needs AWS credentials: Terraform runs without a backend and
# `terraform test` uses mock providers.

SHELL   := /bin/bash
TF      ?= terraform
TFLINT  ?= tflint
PYTHON  ?= python3
VENV    ?= .venv
TF_DIRS := $(sort $(wildcard modules/*)) examples/dev

.DEFAULT_GOAL := help

.PHONY: help init check fmt validate tflint checkov tftest unit lint-python venv clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

init: ## terraform init for every module, the example and the test root (no backend)
	@for dir in . $(TF_DIRS); do \
		echo "==> terraform init $$dir"; \
		$(TF) -chdir=$$dir init -backend=false -input=false -no-color > /dev/null || exit 1; \
	done

check: fmt validate tflint checkov tftest ## All Terraform checks: fmt, validate, tflint, checkov, terraform test

fmt: ## terraform fmt -check
	$(TF) fmt -check -recursive -diff

validate: ## terraform validate every module and the example
	@for dir in $(TF_DIRS); do \
		echo "==> terraform validate $$dir"; \
		$(TF) -chdir=$$dir validate -no-color || exit 1; \
	done

tflint: ## tflint with the terraform (bundled) and AWS rulesets
	$(TFLINT) --init --config "$(CURDIR)/.tflint.hcl"
	$(TFLINT) --recursive --config "$(CURDIR)/.tflint.hcl" --format compact

checkov: $(VENV)/.iac ## checkov security scan (skips are documented in .checkov.yaml)
	$(VENV)/bin/checkov --config-file .checkov.yaml

tftest: ## terraform test with mock_provider "aws"
	$(TF) test -no-color

unit: $(VENV)/.dev ## pytest for the Glue transform logic with local PySpark
	$(VENV)/bin/pytest

lint-python: $(VENV)/.dev ## ruff lint + format check
	$(VENV)/bin/ruff check .
	$(VENV)/bin/ruff format --check .

venv: $(VENV)/.dev ## Create the Python virtualenv

$(VENV)/bin/python:
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/python -m pip install --quiet --upgrade "pip>=25.1"

$(VENV)/.dev: pyproject.toml | $(VENV)/bin/python
	$(VENV)/bin/python -m pip install --quiet --group dev
	@touch $@

$(VENV)/.iac: pyproject.toml | $(VENV)/bin/python
	$(VENV)/bin/python -m pip install --quiet --group iac
	@touch $@

clean: ## Remove local Terraform and Python artefacts
	find . -type d \( -name .terraform -o -name __pycache__ -o -name .pytest_cache -o -name .ruff_cache \) -prune -exec rm -rf {} +
	find . -name '.terraform.lock.hcl' -delete
	rm -rf $(VENV)
