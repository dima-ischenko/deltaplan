------- packages

declare
    procedure drop_pkg(p_name varchar2) is
    begin
        execute immediate 'drop package ' || p_name;
    exception
        when others then
            if sqlcode != -4043 then
                raise;
            end if;
    end;
begin
    drop_pkg('pkg_deltaplan');
end;
/
