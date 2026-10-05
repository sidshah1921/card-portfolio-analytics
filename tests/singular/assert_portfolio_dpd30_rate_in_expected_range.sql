{{ config(severity='warn') }}
-- Business sanity check: the portfolio 30+ DPD rate should sit between 1% and 8% each month.
-- A breach is worth a look but should not block the pipeline.
select statement_month,
       sum(accounts_30plus) / sum(active_accounts) as dpd30_rate
from {{ ref('mart_portfolio_kpis') }}
group by 1
having sum(accounts_30plus) / sum(active_accounts) not between 0.01 and 0.08
