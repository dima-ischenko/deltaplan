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
    drop_tbl('dwv_batch_tmp');
    drop_tbl('dwv_keys_tmp');
    drop_tbl('dwv_log');
    drop_tbl('dwv_watermark');
end;
/
