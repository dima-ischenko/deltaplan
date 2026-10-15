-- Fixture tables. Named in static SQL inside pkg_dwv_test, so they must
-- exist before that package compiles.
begin execute immediate 'drop table inc_test_seen purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table inc_test_expect purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table inc_test_tgt purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table inc_test_b purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/
begin execute immediate 'drop table inc_test_a purge'; exception when others then if sqlcode != -942 then raise; end if; end;
/

create table inc_test_a (
    id         varchar2(10) not null,
    amount     number not null,
    updated_at date not null,
    constraint pk_inc_test_a primary key (id)
);
create table inc_test_b (
    id         varchar2(10) not null,
    amount     number not null,
    updated_at date not null,
    constraint pk_inc_test_b primary key (id)
);
create table inc_test_tgt (
    id     varchar2(10) not null,
    amount number not null,
    touch  number not null,
    constraint pk_inc_test_tgt primary key (id)
);
create table inc_test_expect (
    id     varchar2(10) not null,
    amount number not null,
    touch  number not null,
    constraint pk_inc_test_expect primary key (id)
);
create table inc_test_seen (
    batch_no number not null,
    id       varchar2(10) not null
);
