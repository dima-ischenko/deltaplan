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
