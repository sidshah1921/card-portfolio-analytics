with catalog as (
    select * from {{ ref('product_catalog') }}
),

accounts as (
    select product_name, count(*) as accounts_booked, avg(credit_limit) as avg_credit_limit,
           avg(fico_at_origination) as avg_fico_at_origination
    from {{ ref('stg_accounts') }}
    group by 1
)

select
    c.product_name,
    c.product_family,
    c.target_segment,
    c.annual_fee,
    c.purchase_apr,
    c.rewards_program,
    c.rewards_rate_pct,
    c.launched_year,
    coalesce(a.accounts_booked, 0)          as accounts_booked,
    round(a.avg_credit_limit, 2)            as avg_credit_limit,
    round(a.avg_fico_at_origination, 1)     as avg_fico_at_origination
from catalog as c
left join accounts as a
    on c.product_name = a.product_name
