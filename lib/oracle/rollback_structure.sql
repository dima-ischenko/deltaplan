------- ddl_dml

declare
    procedure drop_tbl(p_name varchar2) is
    begin
        execute immediate 'drop table ' || p_name || ' purge';
    exception
        when others then
            if sqlcode != -942 then
                raise;
            end if;
    end;
begin
    drop_tbl('dpl_batch_tmp');
    drop_tbl('dpl_keys_tmp');
    drop_tbl('dpl_watermark');

    -- leftover names from earlier layouts
    drop_tbl('deltaplan_batch_tmp');
    drop_tbl('deltaplan_keys_tmp');
    drop_tbl('deltaplan_watermark');
    drop_tbl('deltaplan_batch');
    drop_tbl('deltaplan_keys');
    drop_tbl('deltaplan_key');
    drop_tbl('deltaplan_mark');
end;
/
