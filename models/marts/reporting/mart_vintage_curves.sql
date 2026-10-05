-- Grain: origination quarter x product x months on book.
-- Only vintages originated inside the reporting window, and only months on book that
-- every account in the vintage has reached (no partially-observed points).
with account_months as (
    select * from {{ ref('fct_account_month') }}
),

window_bounds as (
    select min(statement_month) as first_month, max(statement_month) as last_month
    from account_months
),

accounts as (
    select
        a.account_id,
        a.product_name,
        a.vintage_quarter,
        a.vintage_quarter_start,
        a.credit_limit,
        min(m.months_on_book) filter (where m.bucket_rank >= 1)   as first_30plus_mob,
        min(m.months_on_book) filter (where m.bucket_rank >= 2)   as first_60plus_mob,
        min(m.months_on_book) filter (where m.is_charge_off)      as charge_off_mob,
        sum(m.gross_charge_off_amount)                            as charge_off_amount
    from {{ ref('dim_account') }} as a
    inner join account_months as m
        on a.account_id = m.account_id
    cross join window_bounds as w
    where a.open_month >= w.first_month
    group by all
),

grid as (
    select distinct
        a.vintage_quarter,
        a.vintage_quarter_start,
        a.product_name,
        cast(unnest(generate_series(
            0,
            date_diff('month', cast(a.vintage_quarter_start + interval 2 month as date), w.last_month)
        )) as integer) as months_on_book
    from accounts as a
    cross join window_bounds as w
),

point_in_time as (
    select
        a.vintage_quarter, a.product_name, m.months_on_book,
        count(*) filter (where m.is_active)           as active_accounts,
        count(*) filter (where m.is_30plus)           as accounts_30plus,
        sum(m.balance) filter (where m.is_active)     as active_balance
    from account_months as m
    inner join accounts as a
        on m.account_id = a.account_id
    group by all
),

cumulative as (
    select
        g.vintage_quarter, g.vintage_quarter_start, g.product_name, g.months_on_book,
        count(*)                                                        as originated_accounts,
        sum(a.credit_limit)                                             as originated_credit_limit,
        count(*) filter (where a.first_30plus_mob <= g.months_on_book)  as cum_ever_30plus_accounts,
        count(*) filter (where a.first_60plus_mob <= g.months_on_book)  as cum_ever_60plus_accounts,
        count(*) filter (where a.charge_off_mob   <= g.months_on_book)  as cum_charged_off_accounts,
        coalesce(sum(a.charge_off_amount) filter (where a.charge_off_mob <= g.months_on_book), 0)
                                                                        as cum_gross_charge_off_amount
    from grid as g
    inner join accounts as a
        on g.vintage_quarter = a.vintage_quarter and g.product_name = a.product_name
    group by all
)

select
    c.vintage_quarter,
    c.vintage_quarter_start,
    c.product_name,
    c.months_on_book,
    c.originated_accounts,
    c.originated_credit_limit,
    coalesce(p.active_accounts, 0)   as active_accounts,
    coalesce(p.accounts_30plus, 0)   as accounts_30plus,
    coalesce(p.active_balance, 0)    as active_balance,
    c.cum_ever_30plus_accounts,
    c.cum_ever_60plus_accounts,
    c.cum_charged_off_accounts,
    c.cum_gross_charge_off_amount,
    round(coalesce(p.accounts_30plus, 0) / nullif(p.active_accounts, 0), 6)   as dpd30_plus_rate,
    round(c.cum_ever_30plus_accounts / c.originated_accounts, 6)              as cum_ever_30plus_rate,
    round(c.cum_ever_60plus_accounts / c.originated_accounts, 6)              as cum_ever_60plus_rate,
    round(c.cum_charged_off_accounts / c.originated_accounts, 6)              as cum_charge_off_rate,
    round(c.cum_gross_charge_off_amount / c.originated_credit_limit, 6)       as cum_charge_off_pct_of_limit
from cumulative as c
left join point_in_time as p
    on c.vintage_quarter = p.vintage_quarter
   and c.product_name = p.product_name
   and c.months_on_book = p.months_on_book
