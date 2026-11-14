-- 02_clean.sql
-- Type the raw rows and put every one of them into exactly one category.
-- Nothing is deleted: rows that are not sales are kept and labelled, so the
-- cleaned tables always reconcile to the raw row count (see 04_quality_report.sql).

create or replace table stg.lines as
with typed as (
    select
        row_id,
        trim(Invoice)                                   as invoice,
        upper(trim(StockCode))                          as stock_code,
        nullif(trim(Description), '')                   as description,
        cast(cast(Quantity as double) as integer)       as quantity,
        cast(InvoiceDate as timestamp)                  as invoice_ts,
        cast(Price as decimal(12, 3))                   as unit_price,
        cast(cast(CustomerID as double) as integer)     as customer_id,
        trim(Country)                                   as country
    from raw.online_retail
),
flagged as (
    select
        *,
        -- The same line appearing more than once on one invoice. These may be
        -- genuine repeat scans, so they are flagged, not removed.
        row_number() over (
            partition by invoice, stock_code, description, quantity,
                         invoice_ts, unit_price, customer_id, country
            order by row_id
        ) > 1                                           as is_repeat_line,
        invoice like 'C%'                               as is_credit_note,
        -- Real products have a 5-digit code (optionally with a letter suffix);
        -- a few legacy ranges are also real products.
        regexp_matches(stock_code, '^[0-9]{5}')
            or stock_code like 'DCGS%'
            or stock_code in ('PADS', 'SP1002')         as is_product_code
    from typed
)
select
    *,
    case
        when stock_code like 'TEST%'                    then 'test'
        when stock_code like 'GIFT%'                    then 'gift_voucher'
        when not is_product_code                        then 'charge'            -- postage, fees, manual adjustments, bad debt
        when unit_price = 0 and customer_id is null     then 'stock_adjustment'  -- damages, losses, recounts
        when unit_price = 0                             then 'free_item'         -- given to a customer at no charge
        when is_credit_note                             then 'return'
        when quantity > 0                               then 'sale'
        else 'unclassified'
    end                                                 as line_type,
    cast(quantity * unit_price as decimal(16, 3))       as amount
from flagged;
