-- Unqualified identifier. Owner is a separate argument.
create or replace function _norm_ident(p_name text, p_label text)
returns text
language plpgsql
set search_path = pg_catalog, :"dwa_schema" as $$
declare
l_name text;
begin
  if p_name is null then
    raise exception 'DWA-20006 % is required', p_label;
  end if;

  l_name := lower(trim(p_name));
  if l_name is null or length(l_name) = 0 then
    raise exception 'DWA-20006 % is required', p_label;
  end if;
  if position('.' in l_name) > 0 then
    raise exception 'DWA-20006 % must be unqualified; pass p_owner for the schema', p_label;
  end if;
  if l_name !~ '^[a-z][a-z0-9_#$]*$' then
    raise exception 'DWA-20022 invalid % %', p_label, p_name;
  end if;

  return l_name;
end;
$$;

-- The relation must be visible and selectable by the caller.
create or replace function _assert_relation(p_owner text, p_table text)
returns void
language plpgsql
set search_path = pg_catalog, :"dwa_schema" as $$
declare
l_reg regclass;
begin
  l_reg := to_regclass(format('%I.%I', p_owner, p_table));
  if l_reg is null then
    raise exception
      'DWA-20022 table %.% does not exist or is not available',
      p_owner, p_table;
  end if;
  if not has_table_privilege(l_reg, 'SELECT') then
    raise exception
      'DWA-20022 table %.% does not exist or is not available',
      p_owner, p_table;
  end if;
end;
$$;

-- When p_owner is set, require that schema. When omitted, resolve the
-- unqualified name on the install schema / public. pg_temp is left out
-- so a leftover session table cannot steal the owner of a permanent one.
create or replace function _qualify_relation(
    p_owner text,
    p_table text,
    p_label text,
    out o_owner text,
    out o_table text
)
language plpgsql
set search_path = :"dwa_schema", public as $$
declare
l_reg  regclass;
l_trim text := lower(trim(p_owner));
begin
  o_table := _norm_ident(p_table, p_label);

  if l_trim is not null and length(l_trim) > 0 then
    o_owner := _norm_ident(l_trim, 'owner');
    perform _assert_relation(o_owner, o_table);
    return;
  end if;

  -- current_schemas(false) skips the implicit pg_temp prefix.
  select lower(n.nspname), c.oid
  into o_owner, l_reg
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where c.relname = o_table
    and c.relkind in ('r', 'p', 'v', 'm', 'f')
    and n.nspname = any (current_schemas(false))
  order by array_position(current_schemas(false), n.nspname)
  limit 1;

  if l_reg is null then
    raise exception
      'DWA-20022 table % does not exist or is not available',
      o_table;
  end if;

  if not has_table_privilege(l_reg, 'SELECT') then
    raise exception
      'DWA-20022 table %.% does not exist or is not available',
      o_owner, o_table;
  end if;
end;
$$;
