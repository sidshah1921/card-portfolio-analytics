{#- Each entity must have one row for every month between its first and last month
    (no missing months mid-life). Returns the rows that follow a gap. -#}
{% test no_gaps_in_months(model, column_name, partition_by) %}
with ordered as (
    select
        {{ partition_by }} as entity_id,
        {{ column_name }} as period_month,
        lag({{ column_name }}) over (partition by {{ partition_by }} order by {{ column_name }}) as prior_month
    from {{ model }}
)
select *
from ordered
where prior_month is not null
  and period_month <> cast(prior_month + interval 1 month as date)
{% endtest %}
