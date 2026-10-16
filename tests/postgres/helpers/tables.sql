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
drop table if exists public.inc_test_debt;
drop table if exists public.inc_test_roll;
drop table if exists inc_test_debt;
drop table if exists inc_test_roll;

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

-- Open rows (closed_at is null) are recaptured every run. deleted_at is a tombstone.
create table public.inc_test_roll (
    id         text not null,
    amount     numeric not null,
    updated_at timestamp not null,
    closed_at  date,
    deleted_at timestamp,
    primary key (id)
);
create table public.inc_test_debt (
    id     text not null,
    as_of  date not null,
    amount numeric not null,
    primary key (id)
);
