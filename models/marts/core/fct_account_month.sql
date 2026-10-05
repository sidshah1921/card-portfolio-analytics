-- Grain: one row per account x statement month.
with transitions as (
    select * from {{ ref('int_bucket_transitions') }}
)

select
    account_id || '-' || strftime(statement_month, '%Y%m')      as account_month_id,
    account_id,
    customer_id,
    product_name,
    statement_month,
    months_on_book,
    months_on_book = 0                                          as is_new_account,

    -- balances
    credit_limit,
    balance,
    min_due,
    payment_amount,
    round(utilization, 4)                                       as utilization,
    {{ utilization_band('utilization') }}                       as utilization_band,
    utilization >= {{ var('high_utilization_threshold') }}      as is_high_utilization,
    -- net new charges = purchases + interest + fees posted since the prior statement
    case when prior_balance is not null
         then balance - (prior_balance - prior_payment_amount) end as net_new_charges,
    case when prior_balance > 0
         then round(prior_payment_amount / prior_balance, 4) end   as payment_rate,

    -- delinquency
    days_past_due,
    delinquency_bucket,
    bucket_rank,
    prior_bucket,
    transition_type,
    delinquency_bucket <> 'CO'                                  as is_active,
    bucket_rank between 1 and 5                                 as is_30plus,
    bucket_rank between 2 and 5                                 as is_60plus,
    bucket_rank between 3 and 5                                 as is_90plus,
    delinquency_bucket = 'CO'                                   as is_charge_off,
    case when delinquency_bucket = 'CO' then balance else 0 end as gross_charge_off_amount,
    prior_bucket is not null                                    as has_prior_month,
    transition_type = 'Roll forward'                            as is_roll_forward,

    -- risk
    fico_score,
    {{ fico_band('fico_score') }}                               as fico_band,
    is_fico_imputed,
    is_late_arriving
from transitions
