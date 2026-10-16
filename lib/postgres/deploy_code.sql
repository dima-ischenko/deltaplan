------- functions
-- Previous argument orders would otherwise remain as overloads.
drop function if exists initialize(text, text, numeric, boolean, boolean, text);
drop function if exists initialize(text, text, numeric, boolean, text);
drop function if exists capture_delta(text, text, text, numeric);
drop function if exists capture_delta(text, text, numeric, text);

\i lib/postgres/functions/_ensure_temp.sql
\i lib/postgres/functions/_object.sql
\i lib/postgres/functions/_debug.sql
\i lib/postgres/functions/_log.sql
\i lib/postgres/functions/_unfinished.sql
\i lib/postgres/functions/_unassigned.sql
\i lib/postgres/functions/_batch_total.sql
\i lib/postgres/functions/_run_lock.sql
\i lib/postgres/functions/initialize.sql
\i lib/postgres/functions/capture_delta.sql
\i lib/postgres/functions/prepare_batches.sql
\i lib/postgres/functions/next_batch.sql
\i lib/postgres/functions/finish_batch.sql
\i lib/postgres/functions/finalize.sql
