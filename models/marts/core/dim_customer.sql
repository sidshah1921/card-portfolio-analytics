with customers as (
    select * from {{ ref('stg_customers') }}
),

accounts as (
    select customer_id, count(*) as number_of_accounts, min(open_date) as first_account_open_date,
           string_agg(distinct product_name, ', ' order by product_name) as products_held
    from {{ ref('stg_accounts') }}
    group by 1
)

select
    c.customer_id,
    c.state,
    c.age_band,
    c.income_band,
    c.acquisition_channel,
    c.customer_since_date,
    coalesce(a.number_of_accounts, 0)  as number_of_accounts,
    a.products_held,
    a.first_account_open_date
from customers as c
left join accounts as a
    on c.customer_id = a.customer_id
