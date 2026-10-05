{#- Audit log of every data test executed by `dbt build` / `dbt test`.
    The table is created on run start and appended to on run end; mart_data_quality
    is a view on top of it so it always reflects the latest run. -#}

{% macro create_test_results_table() %}
    create schema if not exists audit;
    create table if not exists audit.test_results (
        invocation_id   varchar,
        run_started_at  timestamp,
        test_unique_id  varchar,
        test_name       varchar,
        test_type       varchar,
        model_name      varchar,
        column_name     varchar,
        severity        varchar,
        status          varchar,
        failures        bigint,
        execution_time_s double,
        message         varchar,
        logged_at       timestamp
    );
{% endmacro %}

{% macro log_test_results(results) %}
    {%- if not execute -%}{{ return('') }}{%- endif -%}
    {%- set rows = [] -%}
    {%- for r in results if r.node.resource_type == 'test' -%}
        {%- set node = r.node -%}
        {%- set test_metadata = node.to_dict().get('test_metadata') -%}
        {%- set model_kwarg = (test_metadata.get('kwargs', {}).get('model', '') if test_metadata else '') | string -%}
        {%- if node.to_dict().get('attached_node') -%}
            {%- set model_name = node.attached_node.split('.')[-1] -%}
        {%- elif 'source(' in model_kwarg -%}
            {#- source tests: "{{ get_where_subquery(source('raw', 'raw_payments')) }}" -#}
            {%- set model_name = model_kwarg.split("'")[3] -%}
        {%- else -%}
            {#- singular tests: list every model they read -#}
            {%- set dep_names = [] -%}
            {%- for dep in node.depends_on.nodes -%}{%- do dep_names.append(dep.split('.')[-1]) -%}{%- endfor -%}
            {%- set model_name = dep_names | sort | join(', ') -%}
        {%- endif -%}
        {%- set test_type = test_metadata.get('name') if test_metadata else 'singular' -%}
        {%- set message = (r.message or '') | string | replace("'", "''") -%}
        {%- do rows.append(
            "('" ~ invocation_id ~ "', '" ~ run_started_at.strftime('%Y-%m-%d %H:%M:%S') ~ "', '"
            ~ node.unique_id ~ "', '" ~ node.name ~ "', '" ~ test_type ~ "', '" ~ model_name ~ "', "
            ~ ("'" ~ node.column_name ~ "'" if node.column_name else "null") ~ ", '"
            ~ node.config.severity | lower ~ "', '" ~ r.status ~ "', "
            ~ (r.failures if r.failures is not none else 'null') ~ ", "
            ~ (r.execution_time | round(3)) ~ ", '" ~ message[:500] ~ "', current_timestamp)"
        ) -%}
    {%- endfor -%}
    {%- if rows | length > 0 -%}
        insert into audit.test_results values {{ rows | join(',\n') }};
    {%- else -%}
        select 1;
    {%- endif -%}
{% endmacro %}
