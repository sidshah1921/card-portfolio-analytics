{#- Every non-null date must fall on a dim_date day flagged is_in_reporting_window. -#}
{% test within_reporting_window(model, column_name) %}
select m.*
from {{ model }} as m
where m.{{ column_name }} is not null
  and not exists (
      select 1
      from {{ ref('dim_date') }} as d
      where d.is_in_reporting_window
        and d.date_day = cast(m.{{ column_name }} as date)
  )
{% endtest %}
