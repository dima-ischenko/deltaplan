begin
    pkg_dwv_test.reset;
    pkg_dwv_test.add_row('inc_test_a', 'a', 1, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'b', 1, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'c', 1, pkg_dwv_test.c_t1);
    pkg_dwv_test.capture_source('inc_test_a');
    pkg_dwv.prepare_batches(p_batch_size => 2);

    if not pkg_dwv.next_batch then
        pkg_dwv_test.fail('guard finalize', 'missing batch');
    end if;

    begin
        pkg_dwv.finalize;
        pkg_dwv_test.expect_error('guard finalize', -20005);
    exception
        when others then
            if sqlcode != -20005 then
                raise;
            end if;
    end;

    pkg_dwv_test.merge_batch;
    pkg_dwv.finish_batch;

    while pkg_dwv.next_batch loop
        pkg_dwv_test.merge_batch;
        pkg_dwv.finish_batch;
    end loop;

    pkg_dwv.finalize;
    pkg_dwv_test.eq('guard tgt', pkg_dwv_test.tgt_state, 'a:1:1,b:1:1,c:1:1');

    pkg_dwv_test.reset;
    pkg_dwv_test.add_row('inc_test_a', 'a', 1, pkg_dwv_test.c_t1);
    pkg_dwv_test.add_row('inc_test_a', 'b', 1, pkg_dwv_test.c_t1);
    pkg_dwv_test.capture_source('inc_test_a');
    pkg_dwv.prepare_batches(p_batch_size => 1);

    if not pkg_dwv.next_batch then
        pkg_dwv_test.fail('guard next', 'missing batch');
    end if;

    begin
        if pkg_dwv.next_batch then
            null;
        end if;
        pkg_dwv_test.expect_error('guard next', -20014);
    exception
        when others then
            if sqlcode != -20014 then
                raise;
            end if;
    end;

    pkg_dwv_test.merge_batch;
    pkg_dwv.finish_batch;

    while pkg_dwv.next_batch loop
        pkg_dwv_test.merge_batch;
        pkg_dwv.finish_batch;
    end loop;

    pkg_dwv.finalize;

    pkg_dwv_test.reset;
    pkg_dwv_test.add_row('inc_test_a', 'a', 1, pkg_dwv_test.c_t1);
    pkg_dwv_test.capture_source('inc_test_a');
    pkg_dwv.prepare_batches(p_batch_size => 2);

    begin
        pkg_dwv.prepare_batches(p_batch_size => 3);
        pkg_dwv_test.expect_error('guard size', -20009);
    exception
        when others then
            if sqlcode != -20009 then
                raise;
            end if;
    end;

    begin
        pkg_dwv.prepare_batches(p_batch_size => 2, p_commit_batch => false);
        pkg_dwv_test.expect_error('guard commit', -20018);
    exception
        when others then
            if sqlcode != -20018 then
                raise;
            end if;
    end;

    begin
        pkg_dwv_test.capture_source('inc_test_a');
        pkg_dwv_test.expect_error('guard capture', -20013);
    exception
        when others then
            if sqlcode != -20013 then
                raise;
            end if;
    end;

    while pkg_dwv.next_batch loop
        pkg_dwv_test.merge_batch;
        pkg_dwv.finish_batch;
    end loop;

    pkg_dwv.finalize;

    pkg_dwv_test.reset;

    begin
        if pkg_dwv.next_batch then
            null;
        end if;
        pkg_dwv_test.expect_error('guard no prepare', -20016);
    exception
        when others then
            if sqlcode != -20016 then
                raise;
            end if;
    end;

    begin
        pkg_dwv.initialize('no_such_dwv_table');
        pkg_dwv_test.expect_error('guard missing target', -20022);
    exception
        when others then
            if sqlcode != -20022 then
                raise;
            end if;
    end;

    begin
        pkg_dwv.finish_batch;
        pkg_dwv_test.expect_error('guard no batch', -20017);
    exception
        when others then
            if sqlcode != -20017 then
                raise;
            end if;
    end;

    pkg_dwv_test.pass('batch_guards');
end;
/
