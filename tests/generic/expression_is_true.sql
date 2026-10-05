{#- Fails for every row where the boolean SQL expression is not true. -#}
{% test expression_is_true(model, expression, column_name=none, where_clause=none) %}
select *
from {{ model }}
where not coalesce(({{ expression }}), false)
{% if where_clause %}and {{ where_clause }}{% endif %}
{% endtest %}
