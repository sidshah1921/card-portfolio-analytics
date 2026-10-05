-- How staging handled each injected data-quality defect class in the current load.
with statements as (
    select dq_status, is_late_arriving, fico_refresh is null as fico_null
    from {{ ref('base_statements') }}
),

payments as (
    select dq_status, is_late_arriving
    from {{ ref('base_payments') }}
),

checks as (
    select 'raw_statements' as source_table, dq_status as dq_check, 'rejected' as action, count(*) as affected_rows
    from statements where dq_status <> 'valid' group by all
    union all
    select 'raw_statements', 'null_fico_refresh', 'imputed (forward-fill)', count(*)
    from statements where dq_status = 'valid' and fico_null
    union all
    select 'raw_statements', 'late_arriving', 'accepted (flagged)', count(*)
    from statements where dq_status = 'valid' and is_late_arriving
    union all
    select 'raw_payments', dq_status, 'rejected', count(*)
    from payments where dq_status <> 'valid' group by all
    union all
    select 'raw_payments', 'late_arriving', 'accepted (flagged)', count(*)
    from payments where dq_status = 'valid' and is_late_arriving
),

received as (
    select 'raw_statements' as source_table, count(*) as rows_received from statements
    union all
    select 'raw_payments', count(*) from payments
)

select
    c.source_table,
    c.dq_check,
    c.action,
    c.affected_rows,
    r.rows_received,
    round(100.0 * c.affected_rows / r.rows_received, 3) as pct_of_rows_received
from checks as c
inner join received as r
    on c.source_table = r.source_table
