{#- The reporting window is an explicit contract (dbt vars), independent of the data:
    [reporting_window_start, reporting_window_start + reporting_window_months - 1 day].
    Records dated outside it are excluded in staging and counted in the quality marts. -#}
{% macro reporting_window_start() -%}
    cast('{{ var("reporting_window_start") }}' as date)
{%- endmacro %}

{% macro reporting_window_end() -%}
    cast(cast('{{ var("reporting_window_start") }}' as date)
         + interval {{ var("reporting_window_months") }} month - interval 1 day as date)
{%- endmacro %}

{#- mart_dq_rejections action label: out-of-window rows are excluded, not corrupt. -#}
{% macro rejection_action(status) -%}
    case when {{ status }} = 'outside_reporting_window' then 'excluded (outside reporting window)' else 'rejected' end
{%- endmacro %}
