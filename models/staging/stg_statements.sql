{{ config(materialized='table') }}

-- One row per account x statement month: latest load wins, FICO gaps forward-filled.
with valid as (
    select * from {{ ref('base_statements') }}
    where dq_status = 'valid'
)

select
    account_id,
    statement_month,
    balance,
    min_due,
    payment_amount,
    days_past_due,
    fico_refresh                                     as fico_refresh_reported,
    last_value(fico_refresh ignore nulls) over (
        partition by account_id order by statement_month
        rows between unbounded preceding and current row
    )                                                as fico_refresh_filled,
    fico_refresh is null                             as is_fico_imputed,
    is_late_arriving,
    versions_received > 1                            as had_multiple_versions,
    loaded_at
from valid
