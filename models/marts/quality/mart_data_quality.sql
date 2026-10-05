{{ config(materialized='view') }}

-- Latest run only: one row per data test executed in the most recent dbt invocation that
-- ran tests. The full history stays in audit.test_results (see mart_dq_history).
with log as (
    select * from {{ source('audit', 'test_results') }}
),

latest_run as (
    select invocation_id
    from log
    order by run_started_at desc, logged_at desc
    limit 1
)

select
    log.invocation_id,
    log.run_started_at,
    log.test_unique_id,
    log.test_name,
    log.test_type,
    log.model_name,
    log.column_name,
    log.severity,
    log.status,
    log.failures,
    log.execution_time_s,
    log.message,
    log.logged_at
from log
inner join latest_run
    on log.invocation_id = latest_run.invocation_id
