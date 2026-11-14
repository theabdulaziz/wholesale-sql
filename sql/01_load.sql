-- 01_load.sql
-- Land the raw file exactly as delivered: every column as text, plus a row id.
-- Nothing is cleaned here, so every later exclusion can be traced back to a raw row.

create schema if not exists raw;
create schema if not exists stg;
create schema if not exists analysis;

create or replace table raw.online_retail as
select
    row_number() over () as row_id,
    Invoice, StockCode, Description, Quantity, InvoiceDate, Price, CustomerID, Country
from read_csv('data/raw/online_retail_ii.csv', header = true, all_varchar = true);
