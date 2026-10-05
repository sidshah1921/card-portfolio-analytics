{#- Every statement record received, typed and classified. stg_statements keeps only
    dq_status = 'valid'; mart_dq_rejections reports on the rest. -#}
with source as (
    select * from {{ source('raw', 'raw_statements') }}
),

typed as (
    select
        trim(account_id)                                  as account_id,
        cast(statement_month as date)                     as statement_month,
        try_cast(balance as decimal(14, 2))               as balance,
        try_cast(min_due as decimal(14, 2))               as min_due,
        try_cast(payment_amount as decimal(14, 2))        as payment_amount,
        try_cast(days_past_due as integer)                as days_past_due,
        try_cast(nullif(trim(fico_refresh), '') as integer) as fico_refresh,
        cast(_loaded_at as timestamp)                     as loaded_at
    from source
),

versioned as (
    select
        *,
        md5(concat_ws('|', balance, min_due, payment_amount, days_past_due, fico_refresh)) as record_hash,
        row_number() over (
            partition by account_id, statement_month
            order by loaded_at desc, balance desc
        ) as version_rank,
        count(*) over (partition by account_id, statement_month) as versions_received
    from typed
),

classified as (
    select
        v.*,
        -- statement cycles normally land ~33 days after the statement month opens
        v.loaded_at > v.statement_month + interval 45 day as is_late_arriving,
        case
            when a.account_id is null then 'orphan_account'
            when v.balance is null or v.days_past_due is null then 'unparseable'
            when v.statement_month not between {{ reporting_window_start() }} and {{ reporting_window_end() }}
                then 'outside_reporting_window'
            when v.version_rank > 1
                and v.record_hash = first_value(v.record_hash) over (
                    partition by v.account_id, v.statement_month order by v.version_rank
                ) then 'exact_duplicate'
            when v.version_rank > 1 then 'superseded_restatement'
            else 'valid'
        end as dq_status
    from versioned as v
    left join {{ ref('stg_accounts') }} as a
        on v.account_id = a.account_id
)

select * from classified
