-- S16-S19: security, multi-statement capture, ORCA fallback, application's own hint comment
SET gg_planman.log_usage = notice;
TRUNCATE gg_planman.plans;

\echo '=== a role that is not a superuser cannot change the store: the function, the table and the setting refuse ==='
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN CREATE ROLE app_user LOGIN; END IF;
END $$;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT ON t1, t2 TO app_user;
SET ROLE app_user;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 WHERE v < 1', 'Set(work_mem 64kB) SeqScan(t1)');
INSERT INTO gg_planman.plans (key_base, enabled, hints, query, n_oid, n_name, n_regex, identity, created_at) VALUES (1, true, 'x', 'x', 0, 0, 0, '', now());
SET gg_planman.write_mode = on;
RESET ROLE;
SELECT hints FROM gg_planman.plans;

\echo '=== multi-statement query string captured in write mode ==='
TRUNCATE gg_planman.plans;
SET gg_planman.write_mode = on;
