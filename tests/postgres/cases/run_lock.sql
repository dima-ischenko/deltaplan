create extension if not exists dblink;

create or replace procedure dpl_test.run_lock()
language plpgsql as $$
declare
    l_conn text := 'dpl_lock_peer';
begin
    call dpl_test.reset();

    perform initialize('inc_test_tgt', 'all', 0);
    perform initialize('inc_test_tgt', 'all', 0);

    perform initialize('inc_test_tgt', 'fr', 0);
    perform finalize();
    perform initialize('inc_test_tgt', 'all', 0);

    perform dblink_connect(
        l_conn,
        format('dbname=%s user=%s', current_database(), current_user)
    );
    perform dblink_exec(l_conn, 'set search_path to lib, public');

    begin
        perform dblink_exec(
            l_conn,
            'do $dpl$ begin perform initialize(''inc_test_tgt'', ''all'', 0); end; $dpl$'
        );
        call dpl_test.fail('run_lock peer same', 'expected DP-20021');
    exception
        when others then
            if position('DP-20021' in sqlerrm) = 0 then
                raise;
            end if;
    end;

    perform dblink_exec(
        l_conn,
        'do $dpl$ begin perform initialize(''inc_test_tgt'', ''fr'', 0); end; $dpl$'
    );
    perform dblink_exec(
        l_conn,
        'do $dpl$ begin perform finalize(); end; $dpl$'
    );

    perform finalize();

    perform dblink_exec(
        l_conn,
        'do $dpl$ begin perform initialize(''inc_test_tgt'', ''all'', 0); end; $dpl$'
    );
    perform dblink_exec(
        l_conn,
        'do $dpl$ begin perform finalize(); end; $dpl$'
    );
    perform dblink_disconnect(l_conn);

    call dpl_test.pass('run_lock');
end;
$$;

call dpl_test.run_lock();
