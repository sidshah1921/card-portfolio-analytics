{#- Within each group, the column must sum to `target` (+/- tolerance).
    Used to prove roll-rate distributions are complete (each from-bucket sums to 100%). -#}
{% test rows_sum_to(model, column_name, group_by, target=100, tolerance=0.01) %}
select {{ group_by | join(', ') }}, sum({{ column_name }}) as total
from {{ model }}
group by {{ group_by | join(', ') }}
having abs(sum({{ column_name }}) - {{ target }}) > {{ tolerance }}
{% endtest %}
