-- Daily calendar spine (also the MetricFlow time spine). Join monthly facts on date_day = statement_month.
with days as (
    select cast(unnest(generate_series(date '2018-01-01', date '2027-12-31', interval 1 day)) as date) as date_day
)

select
    date_day,
    cast(date_trunc('month', date_day) as date)        as month_start,
    cast(date_trunc('quarter', date_day) as date)      as quarter_start,
    year(date_day)                                     as calendar_year,
    quarter(date_day)                                  as calendar_quarter,
    month(date_day)                                    as calendar_month,
    strftime(date_day, '%b')                           as month_name_short,
    strftime(date_day, '%Y-%m')                        as year_month,
    year(date_day) || '-Q' || quarter(date_day)        as year_quarter,
    dayofweek(date_day)                                as day_of_week,
    date_day = date_trunc('month', date_day)           as is_month_start,
    date_day = last_day(date_day)                      as is_month_end,
    quarter(date_day) = 4                              as is_holiday_quarter,
    date_day between {{ reporting_window_start() }} and {{ reporting_window_end() }}
                                                       as is_in_reporting_window
from days
