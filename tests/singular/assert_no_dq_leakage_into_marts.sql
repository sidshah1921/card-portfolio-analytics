-- Every record staging rejected must be absent from the marts, and the marts must hold
-- exactly one row per valid source record. Returns offending rows (expect none).
with rejected_payments_in_mart as (
    select 'rejected payment in fct_payments' as issue, f.payment_id as record_key
    from {{ ref('fct_payments') }} as f
    inner join {{ ref('base_payments') }} as b
        on f.payment_id = b.payment_id
    where b.dq_status in ('non_positive_amount', 'orphan_account')
),

statement_row_count as (
    select 'fct_account_month row count differs from valid statements' as issue,
           (select count(*) from {{ ref('fct_account_month') }})::varchar || ' vs '
           || (select count(*) from {{ ref('base_statements') }} where dq_status = 'valid')::varchar as record_key
    where (select count(*) from {{ ref('fct_account_month') }})
       <> (select count(*) from {{ ref('base_statements') }} where dq_status = 'valid')
),

superseded_values_in_mart as (
    -- a superseded restatement whose stale balance made it to the fact table
    select 'superseded statement value in fct_account_month' as issue, f.account_month_id as record_key
    from {{ ref('fct_account_month') }} as f
    inner join {{ ref('base_statements') }} as b
        on f.account_id = b.account_id
       and f.statement_month = b.statement_month
       and b.dq_status = 'valid'
    where f.balance <> b.balance
)

select * from rejected_payments_in_mart
union all select * from statement_row_count
union all select * from superseded_values_in_mart
