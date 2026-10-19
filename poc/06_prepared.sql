-- S8: PREPARE / EXECUTE, literal against parameter keys, cached plans.
--     The extension does not invalidate cached plans: a generic plan built before a
--     change of the store lives until the session plans again: DDL on the table,
--     DISCARD PLANS or a reconnection (DBA responsibility).
SET optimizer = off;
SET gg_planman.log_usage = notice;
TRUNCATE gg_planman.plans;
PREPARE p(int) AS SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < $1;

\echo '=== hints registered for the literal form only ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 100', 'NestLoop(t1 t2) Leading((t1 t2))');
EXPLAIN (COSTS off) EXECUTE p(100);

\echo '=== hints registered for the parameter form ==='
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < $1', 'NestLoop(t1 t2) Leading((t1 t2))', '{int4}');
EXPLAIN (COSTS off) EXECUTE p(100);

\echo '=== a generic plan cached before the registration stays unhinted: no invalidation by the extension ==='
DEALLOCATE p;
TRUNCATE gg_planman.plans;
SET plan_cache_mode = force_generic_plan;
PREPARE p(int) AS SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < $1;
EXECUTE p(100);
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < $1', 'NestLoop(t1 t2) Leading((t1 t2))', '{int4}');
EXPLAIN (COSTS off) EXECUTE p(100);
\echo '=== ... until DDL on the table, DISCARD PLANS or a reconnection makes the session plan again; ANALYZE of an unchanged table does not ==='
ANALYZE t1;
EXPLAIN (COSTS off) EXECUTE p(100);
ALTER TABLE t1 ALTER COLUMN pad SET STATISTICS 50;
EXPLAIN (COSTS off) EXECUTE p(100);
\echo '=== the same after the row is switched off by its id: the cached plan keeps the hints until the next DDL ==='
UPDATE gg_planman.plans SET enabled = false WHERE id = (SELECT id FROM gg_planman.plans WHERE paramtypes IS NOT NULL);
EXPLAIN (COSTS off) EXECUTE p(100);
ALTER TABLE t1 ALTER COLUMN pad SET STATISTICS 60;
EXPLAIN (COSTS off) EXECUTE p(100);
ALTER TABLE t1 ALTER COLUMN pad SET STATISTICS -1;
RESET plan_cache_mode;
DEALLOCATE p;
