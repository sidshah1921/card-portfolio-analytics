-- Charge-off happens exactly at 180 DPD and is the account's final month.
select f.account_id, f.statement_month, f.days_past_due, a.last_statement_month
from {{ ref('fct_account_month') }} as f
inner join {{ ref('dim_account') }} as a
    on f.account_id = a.account_id
where f.is_charge_off
  and (f.days_past_due <> 180 or f.statement_month <> a.last_statement_month)
