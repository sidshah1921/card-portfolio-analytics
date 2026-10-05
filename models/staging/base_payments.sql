{#- Every payment record received, typed and classified. -#}
with source as (
    select * from {{ source('raw', 'raw_payments') }}
),

typed as (
    select
        trim(payment_id)                         as payment_id,
        trim(account_id)                         as account_id,
        cast(payment_date as date)               as payment_date,
        try_cast(amount as decimal(14, 2))       as amount,
        cast(_loaded_at as timestamp)            as loaded_at
    from source
),

versioned as (
    select
        *,
        row_number() over (partition by payment_id order by loaded_at, account_id) as delivery_rank
    from typed
)

select
    v.*,
    v.loaded_at > v.payment_date + interval 7 day as is_late_arriving,
    case
        when v.amount is null then 'unparseable'
        when v.amount <= 0 then 'non_positive_amount'
        when a.account_id is null then 'orphan_account'
        when v.delivery_rank > 1 then 'duplicate_payment_id'
        else 'valid'
    end as dq_status
from versioned as v
left join {{ ref('stg_accounts') }} as a
    on v.account_id = a.account_id
