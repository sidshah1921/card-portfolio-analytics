-- Raw -> staging -> mart row funnel per entity, with rejections broken out by defect type.
-- Identity: raw_rows - rejected_rows_total = staged_rows = mart_rows (tested).
with statements as (
    select
        'statements' as entity,
        count(*)                                                        as raw_rows,
        count(*) filter (where dq_status = 'exact_duplicate')           as rejected_exact_duplicate,
        count(*) filter (where dq_status = 'superseded_restatement')    as rejected_superseded_restatement,
        0                                                               as rejected_duplicate_id,
        0                                                               as rejected_non_positive_amount,
        count(*) filter (where dq_status = 'orphan_account')            as rejected_orphan_account,
        count(*) filter (where dq_status = 'unparseable')               as rejected_unparseable,
        count(*) filter (where dq_status = 'valid' and fico_refresh is null) as imputed_rows,
        count(*) filter (where dq_status = 'valid' and is_late_arriving)     as late_arriving_rows
    from {{ ref('base_statements') }}
),

payments as (
    select
        'payments',
        count(*),
        0,
        0,
        count(*) filter (where dq_status = 'duplicate_payment_id'),
        count(*) filter (where dq_status = 'non_positive_amount'),
        count(*) filter (where dq_status = 'orphan_account'),
        count(*) filter (where dq_status = 'unparseable'),
        0,
        count(*) filter (where dq_status = 'valid' and is_late_arriving)
    from {{ ref('base_payments') }}
),

-- accounts and customers are only deduplicated by id in staging
masters as (
    select 'accounts', (select count(*) from {{ source('raw', 'raw_accounts') }}) as raw_rows,
           0, 0, (select count(*) from {{ source('raw', 'raw_accounts') }}) - (select count(*) from {{ ref('stg_accounts') }}),
           0, 0, 0, 0, 0
    union all
    select 'customers', (select count(*) from {{ source('raw', 'raw_customers') }}),
           0, 0, (select count(*) from {{ source('raw', 'raw_customers') }}) - (select count(*) from {{ ref('stg_customers') }}),
           0, 0, 0, 0, 0
),

raw_side as (
    select * from statements
    union all select * from payments
    union all select * from masters
),

downstream as (
    select 'statements' as entity,
           (select count(*) from {{ ref('stg_statements') }})    as staged_rows,
           'fct_account_month'                                     as mart_model,
           (select count(*) from {{ ref('fct_account_month') }}) as mart_rows
    union all
    select 'payments', (select count(*) from {{ ref('stg_payments') }}),
           'fct_payments', (select count(*) from {{ ref('fct_payments') }})
    union all
    select 'accounts', (select count(*) from {{ ref('stg_accounts') }}),
           'dim_account', (select count(*) from {{ ref('dim_account') }})
    union all
    select 'customers', (select count(*) from {{ ref('stg_customers') }}),
           'dim_customer', (select count(*) from {{ ref('dim_customer') }})
)

select
    r.entity,
    r.raw_rows,
    r.rejected_exact_duplicate,
    r.rejected_superseded_restatement,
    r.rejected_duplicate_id,
    r.rejected_non_positive_amount,
    r.rejected_orphan_account,
    r.rejected_unparseable,
    r.rejected_exact_duplicate + r.rejected_superseded_restatement + r.rejected_duplicate_id
        + r.rejected_non_positive_amount + r.rejected_orphan_account + r.rejected_unparseable
                                                    as rejected_rows_total,
    d.staged_rows,
    d.mart_model,
    d.mart_rows,
    r.imputed_rows,
    r.late_arriving_rows,
    round(100.0 * d.mart_rows / r.raw_rows, 3)      as pct_raw_rows_in_mart
from raw_side as r
inner join downstream as d
    on r.entity = d.entity
