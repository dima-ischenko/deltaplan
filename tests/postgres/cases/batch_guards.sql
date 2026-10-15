create or replace procedure dwv_test.batch_guards()
language plpgsql as $$
declare
    c_t1 constant timestamp := timestamp '2024-01-15 10:00:00';
begin
    call dwv_test.reset();
    call dwv_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dwv_test.add_row('inc_test_a', 'b', 1, c_t1);
    call dwv_test.add_row('inc_test_a', 'c', 1, c_t1);
    call dwv_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    if not next_batch() then
        call dwv_test.fail('guard finalize', 'missing batch');
    end if;
    call dwv_test.expect_dwv('guard finalize', 'DWV-20005', 'select finalize()');
    call dwv_test.merge_batch();
    perform finish_batch();
    while next_batch() loop
        call dwv_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();
    call dwv_test.eq('guard tgt', dwv_test.tgt_state(), 'a:1:1,b:1:1,c:1:1');

    call dwv_test.reset();
    call dwv_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dwv_test.add_row('inc_test_a', 'b', 1, c_t1);
    call dwv_test.capture_source('inc_test_a');
    perform prepare_batches(1);
    if not next_batch() then
        call dwv_test.fail('guard next', 'missing batch');
    end if;
    call dwv_test.expect_dwv('guard next', 'DWV-20014', 'select next_batch()');
    call dwv_test.merge_batch();
    perform finish_batch();
    while next_batch() loop
        call dwv_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();

    call dwv_test.reset();
    call dwv_test.add_row('inc_test_a', 'a', 1, c_t1);
    call dwv_test.capture_source('inc_test_a');
    perform prepare_batches(2);
    call dwv_test.expect_dwv(
        'guard size', 'DWV-20009', 'select prepare_batches(3)'
    );
    call dwv_test.expect_dwv(
        'guard capture', 'DWV-20013',
        'call dwv_test.capture_source(''inc_test_a'')'
    );
    while next_batch() loop
        call dwv_test.merge_batch();
        perform finish_batch();
    end loop;
    perform finalize();

    call dwv_test.reset();
    call dwv_test.expect_dwv('guard no prepare', 'DWV-20016', 'select next_batch()');
    call dwv_test.expect_dwv(
        'guard missing target', 'DWV-20022',
        'select initialize(''no_such_dwv_table'')'
    );
    call dwv_test.expect_dwv('guard no batch', 'DWV-20017', 'select finish_batch()');
    call dwv_test.pass('batch_guards');
end;
$$;

call dwv_test.batch_guards();
