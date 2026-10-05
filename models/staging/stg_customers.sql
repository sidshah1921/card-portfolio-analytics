with source as (
    select * from {{ source('raw', 'raw_customers') }}
),

typed as (
    select
        trim(customer_id)                          as customer_id,
        upper(trim(state))                         as state,
        trim(age_band)                             as age_band,
        trim(income_band)                          as income_band,
        trim(acquisition_channel)                  as acquisition_channel,
        cast(open_date as date)                    as customer_since_date,
        cast(_loaded_at as timestamp)              as loaded_at
    from source
    where customer_id is not null
)

-- keep the most recently loaded version of each customer
select * exclude (version_rank)
from (
    select *, row_number() over (partition by customer_id order by loaded_at desc) as version_rank
    from typed
)
where version_rank = 1
