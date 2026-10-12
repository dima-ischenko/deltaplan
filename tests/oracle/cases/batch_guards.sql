begin
    pkg_dpl_test.reset;
    pkg_dpl_test.add_row('inc_test_a', 'a', 1, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_a', 'b', 1, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_a', 'c', 1, pkg_dpl_test.c_t1);
    pkg_dpl_test.capture_source('inc_test_a');
    pkg_dpl.prepare_batches(p_batch_size => 2);

    if not pkg_dpl.next_batch then
        pkg_dpl_test.fail('guard finalize', 'missing batch');
    end if;

    begin
        pkg_dpl.finalize;
        pkg_dpl_test.expect_error('guard finalize', -20005);
    exception
        when others then
            if sqlcode != -20005 then
                raise;
            end if;
    end;

    pkg_dpl_test.merge_batch;
    pkg_dpl.finish_batch;

    while pkg_dpl.next_batch loop
        pkg_dpl_test.merge_batch;
        pkg_dpl.finish_batch;
    end loop;

    pkg_dpl.finalize;
    pkg_dpl_test.eq('guard tgt', pkg_dpl_test.tgt_state, 'a:1:1,b:1:1,c:1:1');

    pkg_dpl_test.reset;
    pkg_dpl_test.add_row('inc_test_a', 'a', 1, pkg_dpl_test.c_t1);
    pkg_dpl_test.add_row('inc_test_a', 'b', 1, pkg_dpl_test.c_t1);
    pkg_dpl_test.capture_source('inc_test_a');
    pkg_dpl.prepare_batches(p_batch_size => 1);

    if not pkg_dpl.next_batch then
        pkg_dpl_test.fail('guard next', 'missing batch');
    end if;

    begin
        if pkg_dpl.next_batch then
            null;
        end if;
        pkg_dpl_test.expect_error('guard next', -20014);
    exception
        when others then
            if sqlcode != -20014 then
                raise;
            end if;
    end;

    pkg_dpl_test.merge_batch;
    pkg_dpl.finish_batch;

    while pkg_dpl.next_batch loop
        pkg_dpl_test.merge_batch;
        pkg_dpl.finish_batch;
    end loop;

    pkg_dpl.finalize;

    pkg_dpl_test.reset;
    pkg_dpl_test.add_row('inc_test_a', 'a', 1, pkg_dpl_test.c_t1);
    pkg_dpl_test.capture_source('inc_test_a');
    pkg_dpl.prepare_batches(p_batch_size => 2);

    begin
        pkg_dpl.prepare_batches(p_batch_size => 3);
        pkg_dpl_test.expect_error('guard size', -20009);
    exception
        when others then
            if sqlcode != -20009 then
                raise;
            end if;
    end;

    begin
        pkg_dpl.prepare_batches(p_batch_size => 2, p_commit => false);
        pkg_dpl_test.expect_error('guard commit', -20018);
    exception
        when others then
            if sqlcode != -20018 then
                raise;
            end if;
    end;

    begin
        pkg_dpl_test.capture_source('inc_test_a');
        pkg_dpl_test.expect_error('guard capture', -20013);
    exception
        when others then
            if sqlcode != -20013 then
                raise;
            end if;
    end;

    while pkg_dpl.next_batch loop
        pkg_dpl_test.merge_batch;
        pkg_dpl.finish_batch;
    end loop;

    pkg_dpl.finalize;

    pkg_dpl_test.reset;

    begin
        if pkg_dpl.next_batch then
            null;
        end if;
        pkg_dpl_test.expect_error('guard no prepare', -20016);
    exception
        when others then
            if sqlcode != -20016 then
                raise;
            end if;
    end;

    begin
        pkg_dpl.finish_batch;
        pkg_dpl_test.expect_error('guard no batch', -20017);
    exception
        when others then
            if sqlcode != -20017 then
                raise;
            end if;
    end;

    pkg_dpl_test.pass('batch_guards');
end;
/
