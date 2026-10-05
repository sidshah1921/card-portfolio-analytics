-- Utilization as a leading indicator: for accounts that are Current in the observation
-- month, how often do they go delinquent over the following 3 / 6 months?
-- Grain: observation month x product x FICO band x utilization band.
-- Only observation months with a full 6-month forward window are included.
with account_months as (
    select * from {{ ref('fct_account_month') }}
),

forward_looking as (
    select
        *,
        max(bucket_rank) over (partition by account_id order by statement_month
                               rows between 1 following and 3 following) as max_rank_next_3m,
        max(bucket_rank) over (partition by account_id order by statement_month
                               rows between 1 following and 6 following) as max_rank_next_6m
    from account_months
),

observable as (
    select f.*
    from forward_looking as f
    where f.delinquency_bucket = 'Current'
      and f.statement_month <= (select max(statement_month) - interval 6 month from account_months)
)

select
    statement_month                                              as observation_month,
    product_name,
    fico_band,
    utilization_band,
    count(*)                                                     as current_accounts,
    sum(balance)                                                 as balance,
    sum(credit_limit)                                            as credit_limit,
    round(sum(balance) / nullif(sum(credit_limit), 0), 4)        as utilization_rate,
    count(*) filter (where max_rank_next_3m >= 1)                as accounts_30plus_next_3m,
    count(*) filter (where max_rank_next_6m >= 2)                as accounts_60plus_next_6m,
    count(*) filter (where max_rank_next_6m >= 6)                as accounts_charged_off_next_6m,
    round(count(*) filter (where max_rank_next_3m >= 1) / count(*), 6) as bad_rate_30plus_3m,
    round(count(*) filter (where max_rank_next_6m >= 2) / count(*), 6) as bad_rate_60plus_6m
from observable
group by all
