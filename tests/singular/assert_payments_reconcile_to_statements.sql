{{ config(severity='warn') }}
-- Cycle payments in fct_payments should sum to the payment_amount on the statement they
-- settle. Payments for the final statement month may still be in flight, so it is excluded.
with paid as (
    select account_id, cycle_statement_month as statement_month, sum(amount) as paid_amount
    from {{ ref('fct_payments') }}
    where payment_type = 'Cycle payment'
    group by all
)

select f.account_id, f.statement_month, f.payment_amount, coalesce(p.paid_amount, 0) as paid_amount
from {{ ref('fct_account_month') }} as f
left join paid as p
    on f.account_id = p.account_id
   and f.statement_month = p.statement_month
where f.statement_month < (select max(statement_month) from {{ ref('fct_account_month') }})
  and abs(f.payment_amount - coalesce(p.paid_amount, 0)) > 0.01
