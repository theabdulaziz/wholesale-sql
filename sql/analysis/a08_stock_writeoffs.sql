-- Question: how much stock is being lost, and why?
-- Technique: free-text notes typed by warehouse staff ("damaged", "?", "thrown away")
--            are grouped into reasons with regular expressions.
-- Values are estimates at each product's average selling price, because the data
-- has no cost prices. Cost would be lower.

create or replace view analysis.stock_adjustments_classified as
select
    a.*,
    d.product_name,
    d.avg_unit_price,
    case
        when a.note is null                                                             then 'no reason recorded'
        when regexp_matches(lower(a.note), 'damag|broke|smash|crush|crack|wet|mould|rust|faulty|wrong|discolour') then 'damaged or faulty'
        when regexp_matches(lower(a.note), 'missing|lost|find|stolen|mia|gone|short')   then 'missing'
        when regexp_matches(lower(a.note), 'destroy|thrown|unsale|unsal|dirty')         then 'destroyed or unsaleable'
        when regexp_matches(lower(a.note), 'mailout|donat|charity|sample|show|display|given') then 'given away or used internally'
        when regexp_matches(lower(a.note), 'dotcom|amazon|ebay|sold as|website|set')    then 'sales channel or set adjustment'
        when regexp_matches(lower(a.note), 'check|count|adjust|found|stock|\?')         then 'stock count correction'
        -- A product name in capitals in the note field is not a reason.
        when a.note = upper(a.note) and length(a.note) > 8                              then 'no reason recorded'
        else 'other note'
    end as reason
from fact_stock_adjustments a
left join dim_product d using (stock_code);

create or replace view analysis.stock_writeoffs_by_reason as
select
    reason,
    count(*)                                                            as adjustment_lines,
    -sum(quantity) filter (where quantity < 0)                          as units_written_off,
    coalesce(sum(quantity) filter (where quantity > 0), 0)              as units_added_back,
    round(-sum(quantity * avg_unit_price) filter (where quantity < 0), 0) as est_selling_value_written_off,
    count(*) filter (where avg_unit_price is null)                      as lines_without_a_price
from analysis.stock_adjustments_classified
group by reason
order by units_written_off desc nulls last;
