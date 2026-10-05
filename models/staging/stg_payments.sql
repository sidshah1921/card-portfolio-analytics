{{ config(materialized='table') }}

select
    payment_id,
    account_id,
    payment_date,
    cast(date_trunc('month', payment_date) as date) as payment_month,
    amount,
    is_late_arriving,
    loaded_at
from {{ ref('base_payments') }}
where dq_status = 'valid'
