with accounts as (
    select * from {{ ref('stg_accounts') }}
),

history as (
    select
        account_id,
        min(statement_month)                                             as first_statement_month,
        max(statement_month)                                             as last_statement_month,
        max(statement_month) filter (where delinquency_bucket = 'CO')    as charge_off_month,
        max(balance)         filter (where delinquency_bucket = 'CO')    as charge_off_amount,
        max(bucket_rank) >= 1                                            as ever_30plus,
        max(bucket_rank) >= 2                                            as ever_60plus,
        arg_max(delinquency_bucket, statement_month)                     as latest_delinquency_bucket,
        arg_max(fico_score, statement_month)                             as latest_fico_score,
        arg_max(balance, statement_month)                                as latest_balance
    from {{ ref('int_account_months') }}
    group by 1
)

select
    a.account_id,
    a.customer_id,
    a.product_name,
    a.credit_limit,
    a.open_date,
    a.open_month,
    year(a.open_date) || '-Q' || quarter(a.open_date)        as vintage_quarter,
    cast(date_trunc('quarter', a.open_date) as date)          as vintage_quarter_start,
    a.fico_at_origination,
    {{ fico_band('a.fico_at_origination') }}                  as fico_band_at_origination,
    a.fico_at_origination < 620                               as is_subprime_at_origination,
    case
        when h.account_id is null then 'Inactive before window'  -- no statements in the reporting window
        when h.charge_off_month is not null then 'Charged Off'
        else 'Open'
    end                                                       as account_status,
    h.first_statement_month,
    h.last_statement_month,
    h.charge_off_month,
    coalesce(h.charge_off_amount, 0)                          as charge_off_amount,
    coalesce(h.ever_30plus, false)                            as ever_30plus,
    coalesce(h.ever_60plus, false)                            as ever_60plus,
    h.latest_delinquency_bucket,
    h.latest_fico_score,
    h.latest_balance
from accounts as a
left join history as h
    on a.account_id = h.account_id
