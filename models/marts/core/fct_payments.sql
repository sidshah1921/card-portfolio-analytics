-- Grain: one row per (valid) payment transaction.
with payments as (
    select * from {{ ref('stg_payments') }}
),

accounts as (
    select account_id, customer_id, product_name, charge_off_month
    from {{ ref('dim_account') }}
)

select
    p.payment_id,
    p.account_id,
    a.customer_id,
    a.product_name,
    p.payment_date,
    p.payment_month,
    -- payments land in the month after the statement they settle
    cast(p.payment_month - interval 1 month as date)            as cycle_statement_month,
    p.amount,
    case
        when a.charge_off_month is not null
             and cast(p.payment_month - interval 1 month as date) > a.charge_off_month
        then 'Recovery'
        else 'Cycle payment'
    end                                                         as payment_type,
    p.is_late_arriving
from payments as p
inner join accounts as a
    on p.account_id = a.account_id
