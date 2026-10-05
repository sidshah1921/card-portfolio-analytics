with source as (
    select * from {{ source('raw', 'raw_accounts') }}
),

typed as (
    select
        trim(account_id)                              as account_id,
        trim(customer_id)                             as customer_id,
        trim(product)                                 as product_name,
        cast(credit_limit as decimal(14, 2))          as credit_limit,
        cast(open_date as date)                       as open_date,
        cast(date_trunc('month', cast(open_date as date)) as date) as open_month,
        cast(fico_at_origination as integer)          as fico_at_origination,
        cast(_loaded_at as timestamp)                 as loaded_at
    from source
    where account_id is not null
)

select * exclude (version_rank)
from (
    select *, row_number() over (partition by account_id order by loaded_at desc) as version_rank
    from typed
)
where version_rank = 1
