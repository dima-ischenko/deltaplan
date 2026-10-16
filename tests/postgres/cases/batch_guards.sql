create or replace procedure dwa_test.batch_guards()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
begin
    call dwa_test.reset();
    call dwa_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dwa_test.add_row('inc_test_a', 'b', 1, c_t1);
    call dwa_test.add_row('inc_test_a', 'c', 1, c_t1);
    call dwa_test.capture_source('inc_test_a');
    perform prepare_batches(p_batch_size => 2);
    if not next_batch() then
        call dwa_test.fail('guard finalize', 'missing batch');
    end if;
    call dwa_test.expect_dwa('guard finalize', 'DWA-20005', 'select finalize()');
    call dwa_test.merge_batch();
    perform finish_batch();
    while next_batch() loop
        call dwa_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();
    call dwa_test.eq('guard tgt', dwa_test.tgt_state(), 'a:1:1,b:1:1,c:1:1');

    call dwa_test.reset();
    call dwa_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dwa_test.add_row('inc_test_a', 'b', 1, c_t1);
    call dwa_test.capture_source('inc_test_a');
    perform prepare_batches(p_batch_size => 1);
    if not next_batch() then
        call dwa_test.fail('guard next', 'missing batch');
    end if;
    call dwa_test.expect_dwa('guard next', 'DWA-20014', 'select next_batch()');
    call dwa_test.merge_batch();
    perform finish_batch();
    while next_batch() loop
        call dwa_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();

    call dwa_test.reset();
    call dwa_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dwa_test.capture_source('inc_test_a');
    perform prepare_batches(p_batch_size => 2);
    call dwa_test.expect_dwa(
        'guard size', 'DWA-20009', 'select prepare_batches(p_batch_size => 3)'
    );
    call dwa_test.expect_dwa(
        'guard capture', 'DWA-20013',
        'call dwa_test.capture_source(''inc_test_a'')'
    );
    while next_batch() loop
        call dwa_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();

    call dwa_test.reset();
    call dwa_test.expect_dwa('guard no prepare', 'DWA-20016', 'select next_batch()');
    call dwa_test.expect_dwa(
        'guard missing target', 'DWA-20022',
        'select initialize(p_target_table => ''no_such_dwa_table'')'
    );
    call dwa_test.expect_dwa('guard no batch', 'DWA-20017', 'select finish_batch()');
    call dwa_test.pass('batch_guards');
end;
$$;

call dwa_test.batch_guards();
