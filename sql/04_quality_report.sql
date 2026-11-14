-- 04_quality_report.sql
-- Where did every raw row go? The total line must equal the raw row count.

create or replace view analysis.data_quality_report as
select
    line_type,
    count(*)                                                as raw_rows,
    round(100.0 * count(*) / sum(count(*)) over (), 2)      as pct_of_rows,
    sum(amount)                                             as amount,
    count(*) filter (where is_repeat_line)                  as repeat_lines,
    sum(amount) filter (where is_repeat_line)               as repeat_line_amount,
    count(*) filter (where customer_id is null)             as rows_without_customer
from stg.lines
group by line_type
order by raw_rows desc;
