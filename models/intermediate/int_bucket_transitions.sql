-- Month-over-month delinquency bucket transition for every account month.
with account_months as (
    select * from {{ ref('int_account_months') }}
),

with_prior as (
    select
        *,
        lag(statement_month)    over w as prior_statement_month,
        lag(delinquency_bucket) over w as prior_bucket,
        lag(bucket_rank)        over w as prior_bucket_rank,
        lag(balance)            over w as prior_balance,
        lag(payment_amount)     over w as prior_payment_amount
    from account_months
    window w as (partition by account_id order by statement_month)
)

select
    *,
    case
        when prior_bucket is null then 'New'
        when bucket_rank > prior_bucket_rank then 'Roll forward'
        when bucket_rank = prior_bucket_rank then 'Stay'
        when bucket_rank = 0 then 'Cure'
        else 'Partial cure'
    end as transition_type
from with_prior
