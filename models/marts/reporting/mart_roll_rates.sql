-- Grain: transition month x product x from-bucket x to-bucket.
-- roll_rate_pct sums to 100 within each (transition_month, product_name, from_bucket).
with transitions as (
    select
        statement_month      as transition_month,
        prior_statement_month as from_month,
        product_name,
        prior_bucket         as from_bucket,
        prior_bucket_rank    as from_bucket_rank,
        delinquency_bucket   as to_bucket,
        bucket_rank          as to_bucket_rank,
        transition_type,
        prior_balance,
        balance
    from {{ ref('int_bucket_transitions') }}
    where prior_bucket is not null
),

counts as (
    select
        transition_month, from_month, product_name,
        from_bucket, from_bucket_rank, to_bucket, to_bucket_rank, transition_type,
        count(*)            as accounts,
        sum(prior_balance)  as from_balance,
        sum(balance)        as to_balance
    from transitions
    group by all
)

select
    *,
    sum(accounts)     over g as from_bucket_accounts,
    sum(from_balance) over g as from_bucket_balance,
    100.0 * accounts / sum(accounts) over g                          as roll_rate_pct,
    100.0 * from_balance / nullif(sum(from_balance) over g, 0)       as balance_roll_rate_pct
from counts
window g as (partition by transition_month, product_name, from_bucket)
