{#- Delinquency bucket from days past due. 180+ DPD is a charge-off (CO). -#}
{% macro dpd_bucket(dpd) -%}
    case
        when {{ dpd }} >= 180 then 'CO'
        when {{ dpd }} >= 150 then '150'
        when {{ dpd }} >= 120 then '120'
        when {{ dpd }} >= 90  then '90'
        when {{ dpd }} >= 60  then '60'
        when {{ dpd }} >= 30  then '30'
        else 'Current'
    end
{%- endmacro %}

{#- Ordinal severity of a bucket (Current = 0 ... CO = 6), used to classify transitions. -#}
{% macro bucket_rank(bucket) -%}
    case {{ bucket }}
        when 'Current' then 0
        when '30' then 1
        when '60' then 2
        when '90' then 3
        when '120' then 4
        when '150' then 5
        when 'CO' then 6
    end
{%- endmacro %}

{% macro fico_band(score) -%}
    case
        when {{ score }} is null then 'Unknown'
        when {{ score }} < 620 then '1. Subprime (<620)'
        when {{ score }} < 660 then '2. Near-prime (620-659)'
        when {{ score }} < 720 then '3. Prime (660-719)'
        when {{ score }} < 780 then '4. Prime+ (720-779)'
        else '5. Super-prime (780+)'
    end
{%- endmacro %}

{% macro utilization_band(util) -%}
    case
        when {{ util }} < 0.10 then '1. <10%'
        when {{ util }} < 0.30 then '2. 10-30%'
        when {{ util }} < 0.50 then '3. 30-50%'
        when {{ util }} < 0.70 then '4. 50-70%'
        when {{ util }} < 0.90 then '5. 70-90%'
        else '6. 90%+'
    end
{%- endmacro %}
