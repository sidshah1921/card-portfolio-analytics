-- Account x month with delinquency bucket, utilization and seasoning attributes.
with statements as (
    select * from {{ ref('stg_statements') }}
),

accounts as (
    select * from {{ ref('stg_accounts') }}
)

select
    s.account_id,
    a.customer_id,
    a.product_name,
    s.statement_month,
    date_diff('month', a.open_month, s.statement_month)       as months_on_book,
    a.credit_limit,
    s.balance,
    s.min_due,
    s.payment_amount,
    s.balance / nullif(a.credit_limit, 0)                     as utilization,
    s.days_past_due,
    {{ dpd_bucket('s.days_past_due') }}                        as delinquency_bucket,
    {{ bucket_rank(dpd_bucket('s.days_past_due')) }}           as bucket_rank,
    coalesce(s.fico_refresh_filled, a.fico_at_origination)    as fico_score,
    s.is_fico_imputed or s.fico_refresh_filled is null        as is_fico_imputed,
    s.is_late_arriving
from statements as s
inner join accounts as a
    on s.account_id = a.account_id
