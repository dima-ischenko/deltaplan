create or replace procedure dpl_test.batch_guards()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
begin
    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'c', 1, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    if not next_batch() then
        call dpl_test.fail('guard finalize', 'missing batch');
    end if;
    call dpl_test.expect_dp('guard finalize', 'DP-20005', 'select finalize()');
    call dpl_test.merge_batch();
    perform finish_batch();
    while next_batch() loop
        call dpl_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();
    call dpl_test.eq('guard tgt', dpl_test.tgt_state(), 'a:1:1,b:1:1,c:1:1');

    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.add_row('inc_test_a', 'b', 1, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(1);
    if not next_batch() then
        call dpl_test.fail('guard next', 'missing batch');
    end if;
    call dpl_test.expect_dp('guard next', 'DP-20014', 'select next_batch()');
    call dpl_test.merge_batch();
    perform finish_batch();
    while next_batch() loop
        call dpl_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();

    call dpl_test.reset();
    call dpl_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dpl_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    call dpl_test.expect_dp(
        'guard size', 'DP-20009', 'select prepare_batches(3)'
    );
    call dpl_test.expect_dp(
        'guard capture', 'DP-20013',
        'call dpl_test.capture_source(''inc_test_a'')'
    );
    while next_batch() loop
        call dpl_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();

    call dpl_test.reset();
    call dpl_test.expect_dp('guard no prepare', 'DP-20016', 'select next_batch()');
    call dpl_test.expect_dp('guard no batch', 'DP-20017', 'select finish_batch()');
    call dpl_test.pass('batch_guards');
end;
$$;

call dpl_test.batch_guards();
