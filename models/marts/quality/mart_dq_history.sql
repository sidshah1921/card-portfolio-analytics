{{ config(materialized='view') }}

-- One row per dbt invocation that ran tests, from the append-only audit log.
select
    invocation_id,
    run_started_at                                            as run_ts,
    count(*)                                                  as tests_total,
    count(*) filter (where status = 'pass')                   as passed,
    count(*) filter (where status = 'warn')                   as warned,
    count(*) filter (where status in ('fail', 'error'))       as errored,
    count(*) filter (where status = 'skipped')                as skipped,
    sum(failures) filter (where status <> 'pass')             as failing_rows
from {{ source('audit', 'test_results') }}
group by all
