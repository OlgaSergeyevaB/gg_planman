-- Demonstration of the PoC gg_planman: plan management for Greengage 7, stored pg_hint_plan hints.
-- Run: ./demo.sh   (or ./demo.sh step, with a pause between the sections)

\set ECHO none
\set QUIET on
SET client_min_messages = warning;
DROP TABLE IF EXISTS t1, t2 CASCADE;
CREATE TABLE t1 (id int, v int, pad text) DISTRIBUTED BY (id);
CREATE TABLE t2 (id int, t1_id int, w int) DISTRIBUTED BY (id);
INSERT INTO t1 SELECT i, i % 10000, repeat('x', 20) FROM generate_series(1, 200000) i;
INSERT INTO t2 SELECT i, (i % 200000) + 1, i % 100 FROM generate_series(1, 400000) i;
CREATE INDEX t1_v_idx ON t1 (v);
CREATE INDEX t2_t1_id_idx ON t2 (t1_id);
ANALYZE t1;
ANALYZE t2;
TRUNCATE gg_planman.plans;
RESET client_min_messages;
\set QUIET off

\echo ''
\echo '╔══════════════════════════════════════════════════════════════════════╗'
\echo '║  PoC gg_planman на Greengage 7: к запросу хранятся хинты pg_hint_plan  ║'
\echo '║  t1 — 200 000 строк, DISTRIBUTED BY (id), индекс по v                ║'
\echo '║  t2 — 400 000 строк, DISTRIBUTED BY (id), индекс по t1_id            ║'
\echo '╚══════════════════════════════════════════════════════════════════════╝'
\echo ''
\echo 'Настройки сессии: gg_planman.log_usage = notice — видно каждое применение хинтов.'
\set QUIET on
SET gg_planman.log_usage = notice;
SET optimizer = off;
\set QUIET off

\echo ''
\echo '══ 1. Проблема: план, который выбирает планировщик Postgres ═══════════════'
\echo ''
\set ECHO queries
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 100;
\set ECHO none
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 2. Захват: DBA один раз выполняет запрос с комментарием-хинтом ════════'
\echo '   gg_planman.write_mode = on: комментарий /*+ ... */ сохраняется в gg_planman.plans'
\echo '   вместе с текстом запроса и списком объектов, от которых запрос зависит.'
\echo ''
\set QUIET on
SET gg_planman.write_mode = on;
\set QUIET off
\set ECHO queries
/*+ NestLoop(t1 t2) IndexScan(t1 t1_v_idx) Leading((t1 t2)) */
SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 100;
\set ECHO none
\set QUIET on
SET gg_planman.write_mode = off;
\set QUIET off
\echo ''
\echo 'Что сохранилось:'
SELECT key_base, key_oid, hints, relnames, reloids::text FROM gg_planman.plans;
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 3. Применение: тот же запрос, другая константа, без комментария ═══════'
\echo '   Ключ не содержит значений констант, поэтому v < 500 находит хинты,'
\echo '   сохранённые для v < 100. План строится заново с реальной константой.'
\echo ''
\set ECHO queries
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\set ECHO none
\echo ''
\echo 'Результат с хинтами и без них одинаковый:'
\set ECHO queries
SELECT count(*) AS with_hints FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
SET gg_planman.enabled = off;
SELECT count(*) AS without_hints FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
SET gg_planman.enabled = on;
\set ECHO none
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 3а. Запрос со своими хинтами в комментарии ════════════════════════════'
\echo '   Хинты, явно написанные в тексте запроса, главнее сохранённых:'
\echo '   применяются они, а сохранённая строка остаётся как была.'
\echo ''
\set ECHO queries
/*+ HashJoin(t1 t2) */ EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\set ECHO none
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 4. Ключ запроса: что игнорируется, а что нет ══════════════════════════'
\echo '   gg_planman.query_key() считает ключи для текста запроса, ничего не выполняя.'
\echo ''
SELECT q AS "вариант запроса", key_base, key_oid FROM (
          SELECT 1 AS n, 'исходный: v < 100' AS q, * FROM gg_planman.query_key('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 100')
UNION ALL SELECT 2, 'другая константа: v < 999999', * FROM gg_planman.query_key('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 999999')
UNION ALL SELECT 3, 'другое форматирование и регистр', * FROM gg_planman.query_key(E'select COUNT(*)\n   from T1 join T2 on T1.ID=T2.T1_ID\n  where T1.V<100')
UNION ALL SELECT 4, 'имена со схемой public.t1', * FROM gg_planman.query_key('SELECT count(*) FROM public.t1 JOIN public.t2 ON t1.id = t2.t1_id WHERE t1.v < 100')
UNION ALL SELECT 5, 'алиасы a, b — другой ключ', * FROM gg_planman.query_key('SELECT count(*) FROM t1 a JOIN t2 b ON a.id = b.t1_id WHERE a.v < 100')
UNION ALL SELECT 6, 'параметр $1 — другой ключ', * FROM gg_planman.query_key('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < $1', '{int4}')
UNION ALL SELECT 7, 'литерал 100.0 (numeric) — другой ключ', * FROM gg_planman.query_key('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 100.0')
) s ORDER BY n;
\echo 'Строки 1–4 совпадают: константы, форматирование и схема в ключи не входят.'
\echo 'key_base не содержит таблиц вовсе, key_oid — свёртка key_base с OID таблиц запроса.'
\echo 'Алиасы входят намеренно: pg_hint_plan адресует таблицы по алиасу.'
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 5. Регистрация без выполнения запроса: prepared statement ═════════════'
\echo '   Приложение шлёт запрос с параметром $1. DBA регистрирует хинты'
\echo '   по тексту с $1 и типом параметра — сам запрос выполнять не нужно.'
\echo ''
\set ECHO queries
PREPARE p(int) AS SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < $1;
EXPLAIN (COSTS off) EXECUTE p(100);
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < $1', 'NestLoop(t1 t2) Leading((t1 t2))', '{int4}');
EXPLAIN (COSTS off) EXECUTE p(100);
\set ECHO none
DEALLOCATE p;
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 6. Таблица пересоздана: служебная проверка показывает, какие хинты не работают ══'
\echo '   Строка сопоставляется с таблицей по OID. Когда таблицу удаляют, зависящие от неё'
\echo '   строки по OID перестают применяться; gg_planman.check() показывает их с причиной,'
\echo '   ничего не записывая в хранилище, а check(regenerate => true) регистрирует заново.'
\echo ''
\set QUIET on
SET client_min_messages = warning;
CREATE TABLE t1_new (id int, v int, pad text) DISTRIBUTED BY (id);
INSERT INTO t1_new SELECT * FROM t1;
DROP TABLE t1;
ALTER TABLE t1_new RENAME TO t1;
CREATE INDEX t1_v_idx ON t1 (v);
ANALYZE t1;
RESET client_min_messages;
\set QUIET off
\echo 'Ночная загрузка пересоздала t1: новая таблица, то же имя, тот же индекс.'
\echo ''
\set ECHO queries
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
SELECT identity, state, reason FROM gg_planman.check();
\set ECHO none
\echo ''
\echo '-- перегенерация одной командой: текст запроса и типы параметров уже в хранилище'
\set ECHO queries
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);
SELECT id, hints, reloids::text FROM gg_planman.plans ORDER BY created_at;
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\set ECHO none
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 7. Временные таблицы: другая сессия, своя временная таблица ═══════════'
\echo '   У временной таблицы в каждой сессии свой OID. DBA указывает её в by_name,'
\echo '   и строка сопоставляется с ней по имени; без этого регистрация отклоняется.'
\echo ''
\set ECHO queries
CREATE TEMP TABLE tt AS SELECT * FROM t1 WHERE v < 2000 DISTRIBUTED BY (id);
CREATE INDEX tt_v_idx ON tt (v);
ANALYZE tt;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM tt WHERE v = 1', 'SeqScan(tt)', by_name => '{pg_temp.tt}');
\set ECHO none
\echo ''
\echo '-- \\c: новое соединение, новая сессия, свой pg_temp'
\set QUIET on
\c
SET gg_planman.log_usage = notice;
SET optimizer = off;
\set QUIET off
\set ECHO queries
CREATE TEMP TABLE tt AS SELECT * FROM t1 WHERE v < 2000 DISTRIBUTED BY (id);
CREATE INDEX tt_v_idx ON tt (v);
ANALYZE tt;
EXPLAIN (COSTS off) SELECT count(*) FROM tt WHERE v = 20;
\set ECHO none
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 7а. Функция удалена и создана заново ═════════════════════════════════'
\echo ''
\set QUIET on
SET client_min_messages = warning;
DROP FUNCTION IF EXISTS demo_f(int);
CREATE FUNCTION demo_f(int) RETURNS int AS 'select $1' LANGUAGE sql IMMUTABLE;
RESET client_min_messages;
\set QUIET off
\set ECHO queries
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 WHERE demo_f(v) < 1', 'SeqScan(t1)');
DROP FUNCTION demo_f(int);
CREATE FUNCTION demo_f(int) RETURNS int AS 'select $1' LANGUAGE sql IMMUTABLE;
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);
EXPLAIN (COSTS off) SELECT count(*) FROM t1 WHERE demo_f(v) < 50;
\set ECHO none
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 8. Direct dispatch сохраняется ═══════════════════════════════════════'
\echo '   Точечный запрос по ключу распределения с хинтами по-прежнему'
\echo '   уходит на один сегмент: план строится с реальной константой.'
\echo ''
\set QUIET on
SET optimizer = on;
\set QUIET off
\set ECHO queries
SELECT * FROM gg_planman.register_hints('SELECT * FROM t1 WHERE id = 1 AND v < 1', 'IndexScan(t1 t1_v_idx)');
EXPLAIN (COSTS off) SELECT * FROM t1 WHERE id = 123 AND v < 50;
\set ECHO none
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 9. Внутри PL/pgSQL ═══════════════════════════════════════════════════'
\echo ''
\set QUIET on
SET optimizer = off;
LOAD 'auto_explain';
SET auto_explain.log_min_duration = 0;
SET auto_explain.log_nested_statements = on;
\set QUIET off
\set ECHO queries
CREATE OR REPLACE FUNCTION f_cnt(x int) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE r bigint;
BEGIN
  SELECT count(*) INTO r FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < x;
  RETURN r;
END $$;
\set ECHO none
\echo '-- client_min_messages = log, чтобы auto_explain показал план вложенного запроса'
\set QUIET on
SET client_min_messages = log;
\set QUIET off
\set ECHO queries
SELECT f_cnt(500);
\set ECHO none
\set QUIET on
RESET client_min_messages;
RESET auto_explain.log_min_duration;
\set QUIET off
\echo '(план вложенного запроса выше выведен auto_explain: Nested Loop по хинтам)'
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 10. ORCA: что из хинтов понимает, а что нет ═══════════════════════════'
\echo ''
\set QUIET on
SET optimizer = on;
\set QUIET off
\echo '-- без хинтов'
\set ECHO queries
SET gg_planman.enabled = off;
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
SET gg_planman.enabled = on;
\set ECHO none
\echo ''
\echo '-- NestLoop(t1 t2): ORCA метод соединения игнорирует'
\set ECHO queries
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'NestLoop(t1 t2)');
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\set ECHO none
\echo ''
\echo '-- SeqScan(t1): метод доступа ORCA выполняет'
\set ECHO queries
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'SeqScan(t1)');
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\set ECHO none
\echo ''
\echo '-- Обход: Set(optimizer off) в хинтах — этот запрос планирует Postgres,'
\echo '   и все хинты работают; для сессии optimizer остаётся on'
\set ECHO queries
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1', 'Set(optimizer off) NestLoop(t1 t2) Leading((t1 t2))');
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
SHOW optimizer;
\set ECHO none
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ 11. Отключение и включение сохранённых хинтов ════════════════════════'
\echo '   у строки есть id: он в результате регистрации, в строке журнала и в таблице;'
\echo '   DBA переключает строку обычным UPDATE. Кэшированные планы сессий расширение'
\echo '   не сбрасывает: они перестраиваются после DDL по таблице или переподключения.'
\echo ''
\set ECHO queries
SELECT id, enabled, hints FROM gg_planman.plans ORDER BY id;
UPDATE gg_planman.plans SET enabled = false WHERE id = (SELECT min(id) FROM gg_planman.plans WHERE query = 'SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 1');
EXPLAIN (COSTS off) SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v < 500;
\set ECHO none

\echo ''
\echo '══ 12. Таблицы по имени и по шаблону ════════════════════════════════════'
\echo '   Обычно строка сопоставляется с таблицами запроса по OID. В by_name DBA'
\echo '   называет таблицы, которые сопоставляются по имени, в by_regex — по'
\echo '   регулярному выражению: одна строка обслуживает все подходящие таблицы.'
\echo ''
\set QUIET on
SET client_min_messages = warning;
DROP TABLE IF EXISTS sales_2025, sales_2026;
CREATE TABLE sales_2025 (id int, v int) DISTRIBUTED BY (id);
CREATE TABLE sales_2026 (id int, v int) DISTRIBUTED BY (id);
INSERT INTO sales_2025 SELECT i, i % 1000 FROM generate_series(1, 50000) i;
INSERT INTO sales_2026 SELECT i, i % 1000 FROM generate_series(1, 50000) i;
CREATE INDEX sales_2025_v_idx ON sales_2025 (v);
CREATE INDEX sales_2026_v_idx ON sales_2026 (v);
ANALYZE sales_2025;
ANALYZE sales_2026;
RESET client_min_messages;
SET optimizer = off;
\set QUIET off
\set ECHO queries
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM sales_2026 s WHERE s.v < 1', 'SeqScan(s)', by_regex => '{^public\\.sales_}');
EXPLAIN (COSTS off) SELECT count(*) FROM sales_2025 s WHERE s.v < 50;
\set ECHO none
\echo ''
\echo '-- строка с точным именем специфичнее шаблона, а строка по OID специфичнее обеих'
\set ECHO queries
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM sales_2026 s WHERE s.v < 1', 'IndexScan(s sales_2026_v_idx)', by_name => '{sales_2026}');
EXPLAIN (COSTS off) SELECT count(*) FROM sales_2026 s WHERE s.v < 50;
EXPLAIN (COSTS off) SELECT count(*) FROM sales_2025 s WHERE s.v < 50;
SELECT key_oid IS NOT NULL AS by_oid, hints, rules, patterns FROM gg_planman.plans WHERE 'sales_2026' = ANY(relnames) ORDER BY created_at;
\set ECHO none
\set QUIET on
DROP TABLE sales_2025, sales_2026;
\set QUIET off
\if :{?step}
\prompt 'Enter → дальше ' dummy
\endif

\echo ''
\echo '══ Что осталось в хранилище ══════════════════════════════════════════════'
SELECT enabled, hints, rules, left(query, 40) AS query FROM gg_planman.plans ORDER BY created_at;
\echo ''
\set QUIET on
DROP FUNCTION IF EXISTS demo_f(int);
\set QUIET off
\echo 'Конец демонстрации. Открыть psql: ./demo.sh psql'
