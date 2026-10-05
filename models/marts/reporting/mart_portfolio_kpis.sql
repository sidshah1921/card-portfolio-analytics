-- Grain: statement month x product. Count / amount columns are additive across products;
-- recompute rate columns from their numerators and denominators when rolling up.
with account_months as (
    select * from {{ ref('fct_account_month') }}
),

recoveries as (
    select payment_month, product_name, sum(amount) as recoveries_amount
    from {{ ref('fct_payments') }}
    where payment_type = 'Recovery'
    group by all
),

monthly as (
    select
        statement_month,
        product_name,
        count(*) filter (where is_active)                                as active_accounts,
        count(*) filter (where is_new_account)                           as new_accounts,
        sum(balance) filter (where is_active)                            as total_balance,
        sum(credit_limit) filter (where is_active)                       as total_credit_limit,
        count(*) filter (where is_30plus)                                as accounts_30plus,
        count(*) filter (where is_60plus)                                as accounts_60plus,
        count(*) filter (where is_90plus)                                as accounts_90plus,
        coalesce(sum(balance) filter (where is_30plus), 0)               as balance_30plus,
        count(*) filter (where is_charge_off)                            as charge_off_accounts,
        sum(gross_charge_off_amount)                                     as gross_charge_off_amount,
        sum(payment_amount) filter (where is_active)                     as payments_amount,
        count(*) filter (where prior_bucket = 'Current')                 as prior_current_accounts,
        count(*) filter (where prior_bucket = 'Current' and delinquency_bucket = '30') as current_to_30_accounts,
        count(*) filter (where has_prior_month)                          as roll_eligible_accounts,
        count(*) filter (where is_roll_forward)                          as roll_forward_accounts,
        avg(fico_score) filter (where is_active)                         as avg_fico_score
    from account_months
    group by all
)

select
    m.statement_month,
    m.product_name,
    m.active_accounts,
    m.new_accounts,
    m.total_balance,
    m.total_credit_limit,
    m.accounts_30plus,
    m.accounts_60plus,
    m.accounts_90plus,
    m.balance_30plus,
    m.charge_off_accounts,
    m.gross_charge_off_amount,
    coalesce(r.recoveries_amount, 0)                                       as recoveries_amount,
    m.gross_charge_off_amount - coalesce(r.recoveries_amount, 0)           as net_charge_off_amount,
    m.payments_amount,
    m.prior_current_accounts,
    m.current_to_30_accounts,
    m.roll_eligible_accounts,
    m.roll_forward_accounts,
    round(m.avg_fico_score, 1)                                             as avg_fico_score,
    round(m.total_balance / nullif(m.total_credit_limit, 0), 6)            as utilization_rate,
    round(m.accounts_30plus / nullif(m.active_accounts, 0), 6)             as delinquency_rate_30plus,
    round(m.balance_30plus / nullif(m.total_balance, 0), 6)                as delinquency_rate_30plus_balance,
    round(m.accounts_60plus / nullif(m.active_accounts, 0), 6)             as delinquency_rate_60plus,
    round(m.current_to_30_accounts / nullif(m.prior_current_accounts, 0), 6) as roll_rate_current_to_30,
    round(m.roll_forward_accounts / nullif(m.roll_eligible_accounts, 0), 6)  as roll_rate,
    round(12 * (m.gross_charge_off_amount - coalesce(r.recoveries_amount, 0))
          / nullif(m.total_balance, 0), 6)                                 as net_charge_off_rate_annualized
from monthly as m
left join recoveries as r
    on m.statement_month = r.payment_month
   and m.product_name = r.product_name
