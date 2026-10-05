{#- Balance must not exceed credit limit x tolerance (over-limit via fees/interest is
    tolerated up to the multiplier). -#}
{% test balance_within_limit(model, column_name, limit_column, multiplier=1.1) %}
select *
from {{ model }}
where {{ column_name }} > {{ limit_column }} * {{ multiplier }}
{% endtest %}
