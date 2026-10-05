PYTHON   ?= .venv/bin/python
DBT      ?= .venv/bin/dbt
ACCOUNTS ?= 50000
MONTHS   ?= 36
START    ?= 2023-01
SEED     ?= 42
# The reporting-window contract passed to dbt always matches the generated data.
DBT_VARS := --vars '{reporting_window_start: "$(START)-01", reporting_window_months: $(MONTHS)}'
export DBT_PROFILES_DIR := $(CURDIR)

.PHONY: all setup data build docs export metrics clean

all: data build export          ## generate data, build + test the warehouse, export marts

setup:                          ## create the virtualenv and install dependencies
	python3.11 -m venv .venv
	$(PYTHON) -m pip install --upgrade pip
	$(PYTHON) -m pip install -r requirements.txt

data:                           ## generate synthetic raw CSVs into data/raw/
	$(PYTHON) scripts/generate_data.py --accounts $(ACCOUNTS) --months $(MONTHS) --start $(START) --seed $(SEED)

build:                          ## dbt seed + run + test (dbt build), then generate docs
	$(DBT) build $(DBT_VARS)
	$(DBT) docs generate $(DBT_VARS)

docs: build                     ## serve dbt docs locally
	$(DBT) docs serve

export:                         ## export every mart to data/exports/*.csv for Tableau
	$(PYTHON) scripts/export_for_tableau.py

metrics:                        ## run example MetricFlow queries -> docs/metric_examples.md
	$(DBT) parse --quiet $(DBT_VARS)
	$(PYTHON) scripts/metric_examples.py

clean:
	$(DBT) clean
	rm -f data/warehouse.duckdb data/warehouse.duckdb.wal data/raw/*.csv data/exports/*.csv
