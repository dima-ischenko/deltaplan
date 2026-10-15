create or replace function _log(
    p_proc text,
    p_rows numeric,
    p_text text default null
)
returns void
language plpgsql
set search_path = pg_temp, :"dwv_schema", public as $$
begin
  raise notice '%: % | %', p_proc, coalesce(p_rows, 0), coalesce(p_text, '');

  if to_regclass('dwv_session_tmp') is null then
    return;
  end if;

  if coalesce((select log_table from dwv_session_tmp where id = 1), false) then
    insert into dwv_log (
      logged_at, proc_name, target_owner, target_table, data_slice,
      batch_no, log_rows, message
    )
    select clock_timestamp()::timestamp,
       p_proc,
       s.target_owner,
       s.target_table,
       s.data_slice,
       s.batch_no,
       p_rows,
       left(p_text, 4000)
    from dwv_session_tmp s
    where s.id = 1;
  end if;
end;
$$;
