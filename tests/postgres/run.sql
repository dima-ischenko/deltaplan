-- Rebuild into schema lib (not public) and run the checks.
-- psql "postgresql://user:password@localhost:5432/db" -v ON_ERROR_STOP=1 -f tests/postgres/run.sql

\set ON_ERROR_STOP on
\set dpl_schema lib
drop schema if exists deltaplan_test cascade;
drop schema if exists lib cascade;
create schema lib;
\ir ../../postgres/rollback.sql
\ir ../../postgres/deploy.sql
set search_path to lib, public;

drop table if exists public.inc_test_seen;
drop table if exists public.inc_test_expect;
drop table if exists public.inc_test_tgt;
drop table if exists public.inc_test_b;
drop table if exists public.inc_test_a;
drop table if exists inc_test_seen;
drop table if exists inc_test_expect;
drop table if exists inc_test_tgt;
drop table if exists inc_test_b;
drop table if exists inc_test_a;

create table public.inc_test_a (
    id         text not null,
    amount     numeric not null,
    updated_at timestamp not null,
    primary key (id)
);
create table public.inc_test_b (
    id         text not null,
    amount     numeric not null,
    updated_at timestamp not null,
    primary key (id)
);
create table public.inc_test_tgt (
    id     text not null,
    amount numeric not null,
    touch  numeric not null,
    primary key (id)
);
create table public.inc_test_expect (
    id     text not null,
    amount numeric not null,
    touch  numeric not null,
    primary key (id)
);
create table public.inc_test_seen (
    batch_no numeric not null,
    id       text not null
);

\ir deltaplan_test.sql

delete from dpl_watermark
where target_table in ('inc_test_tgt', 'other_tgt');

call deltaplan_test.run();
