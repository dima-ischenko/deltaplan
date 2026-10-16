-- Exclusive session lock on (owner, target, slice). Survives COMMIT (not xact-scoped).
-- Released in finalize, or when the session ends. Same-session initialize keeps it.
--
-- PostgreSQL has no named advisory locks. The name is the same string Oracle
-- passes to DBMS_LOCK.ALLOCATE_UNIQUE: 'DWA|' || owner || '.' || target || '|' || slice.
-- 4478785 is 0x00445741 ('DWA'); objid is hashtext of that name.
create or replace function _acquire_run_lock(p_owner text, p_target text, p_slice text)
returns void
language plpgsql
set search_path = pg_catalog, :"dwa_schema" as $$
declare
c_ns   constant integer := 4478785;
l_name text := 'DWA|' || p_owner || '.' || p_target || '|' || p_slice;
l_id   integer := hashtext(l_name);
l_old  integer;
begin
  if exists (
    select 1
    from pg_locks
    where locktype = 'advisory'
      and granted
      and pid = pg_backend_pid()
      and objsubid = 2
      and classid::integer = c_ns
      and objid::integer = l_id
  ) then
    perform _log('initialize', 0, 'lock already held name=' || l_name);
    return;
  end if;

  for l_old in
    select objid::integer
    from pg_locks
    where locktype = 'advisory'
      and granted
      and pid = pg_backend_pid()
      and objsubid = 2
      and classid::integer = c_ns
      and objid::integer is distinct from l_id
  loop
    perform pg_advisory_unlock(c_ns, l_old);
    perform _log('initialize', 0, 'lock released previous');
  end loop;

  if not pg_try_advisory_lock(c_ns, l_id) then
    perform _log('initialize', 0, 'lock busy name=' || l_name);
    raise exception
      'DWA-20021 another run is active for %.% / %',
      p_owner, p_target, p_slice;
  end if;

  perform _log('initialize', 0, 'lock acquired name=' || l_name);
end;
$$;

create or replace function _release_run_lock(p_owner text, p_target text, p_slice text)
returns void
language plpgsql
set search_path = pg_catalog, :"dwa_schema" as $$
declare
c_ns   constant integer := 4478785;
l_name text := 'DWA|' || p_owner || '.' || p_target || '|' || p_slice;
begin
  if pg_advisory_unlock(c_ns, hashtext(l_name)) then
    perform _log('finalize', 0, 'lock released name=' || l_name);
  end if;
end;
$$;
