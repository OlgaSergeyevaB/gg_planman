-- Examples for the customer overview (docs/plan_management/planman_overview_plan_management.md).
-- Runs on the PoC cluster under the default optimizer.
\set QUIET on
SET client_min_messages = warning;
DROP TABLE IF EXISTS customers, orders, orders_new CASCADE;
CREATE TABLE customers (id int, region text, name text) DISTRIBUTED BY (id);
CREATE TABLE orders (id int, customer_id int, amount numeric, order_date date) DISTRIBUTED BY (id);
INSERT INTO customers SELECT i, (ARRAY['North','South','East','West'])[1 + i % 4], 'customer ' || i FROM generate_series(1, 50000) i;
INSERT INTO orders SELECT i, 1 + i % 50000, (i % 1000)::numeric, date '2026-01-01' + (i % 270) FROM generate_series(1, 300000) i;
CREATE INDEX orders_customer_id_idx ON orders (customer_id);
CREATE INDEX orders_order_date_idx ON orders (order_date);
ANALYZE customers;
ANALYZE orders;
TRUNCATE gg_planman.plans;
RESET client_min_messages;
\set QUIET off
\pset footer off
SET gg_planman.log_usage = notice;

\echo '=== 1.1 store hints from the query text ==='
SELECT * FROM gg_planman.register_hints($q$
    SELECT c.region, sum(o.amount)
      FROM customers c JOIN orders o ON o.customer_id = c.id
     WHERE o.order_date >= '2026-09-20'
     GROUP BY c.region
$q$, 'SeqScan(o)');

\echo '=== 1.2 the application sends the query with another date ==='
EXPLAIN (COSTS off)
SELECT c.region, sum(o.amount)
  FROM customers c JOIN orders o ON o.customer_id = c.id
 WHERE o.order_date >= '2026-08-01'
 GROUP BY c.region;

\echo '=== 1.3 the same by running the query once with a hint comment ==='
SET gg_planman.write_mode = on;
/*+ SeqScan(o) */
SELECT c.region, sum(o.amount)
  FROM customers c JOIN orders o ON o.customer_id = c.id
 WHERE o.order_date >= '2026-09-20'
 GROUP BY c.region;
SET gg_planman.write_mode = off;

\echo '=== 1.4 a query the application sends with a parameter ==='
SELECT * FROM gg_planman.register_hints($q$
    SELECT c.region, sum(o.amount)
      FROM customers c JOIN orders o ON o.customer_id = c.id
     WHERE o.order_date >= $1
     GROUP BY c.region
$q$, 'SeqScan(o)', '{date}');
PREPARE report(date) AS
    SELECT c.region, sum(o.amount)
      FROM customers c JOIN orders o ON o.customer_id = c.id
     WHERE o.order_date >= $1
     GROUP BY c.region;
EXPLAIN (COSTS off) EXECUTE report('2026-08-01');
DEALLOCATE report;

\echo '=== 1.5 what is stored ==='
SELECT enabled, hints, paramtypes, relnames FROM gg_planman.plans ORDER BY created_at;

\echo '=== 1.6 a join method: the query goes to the Postgres planner ==='
SELECT * FROM gg_planman.register_hints($q$
    SELECT c.region, sum(o.amount)
      FROM customers c JOIN orders o ON o.customer_id = c.id
     WHERE o.order_date >= '2026-09-20'
     GROUP BY c.region
$q$, 'Set(optimizer off) NestLoop(o c) Leading((o c))');
EXPLAIN (COSTS off)
SELECT c.region, sum(o.amount)
  FROM customers c JOIN orders o ON o.customer_id = c.id
 WHERE o.order_date >= '2026-08-01'
 GROUP BY c.region;

\echo '=== 1.7 a load recreates the table ==='
CREATE TABLE orders_new (LIKE orders) DISTRIBUTED BY (id);
INSERT INTO orders_new SELECT * FROM orders;
DROP TABLE orders;
ALTER TABLE orders_new RENAME TO orders;
CREATE INDEX orders_customer_id_idx ON orders (customer_id);
CREATE INDEX orders_order_date_idx ON orders (order_date);
ANALYZE orders;
SELECT identity, state, reason FROM gg_planman.check();
SELECT identity, state, reason FROM gg_planman.check(regenerate => true);
SELECT hints, reloids::text FROM gg_planman.plans ORDER BY created_at;

\echo '=== 1.8 switch stored hints off by the row id, and remove them ==='
SELECT id, enabled, left(query, 50) AS query FROM gg_planman.plans ORDER BY id;
UPDATE gg_planman.plans SET enabled = false WHERE id IN (SELECT id FROM gg_planman.plans WHERE query LIKE '%sum(o.amount)%');
SELECT id, enabled FROM gg_planman.plans ORDER BY id;
DELETE FROM gg_planman.plans WHERE NOT enabled;

\echo '=== 2. temporary table: register in one session ==='
CREATE TEMP TABLE stage_orders AS
    SELECT * FROM orders WHERE order_date >= '2026-09-01' DISTRIBUTED BY (id);
CREATE INDEX stage_orders_amount_idx ON stage_orders (amount);
ANALYZE stage_orders;
SELECT * FROM gg_planman.register_hints($q$
    SELECT count(*) FROM stage_orders s JOIN customers c ON c.id = s.customer_id WHERE s.amount > 990
$q$, 'SeqScan(s)', by_name => '{pg_temp.stage_orders}');
\echo '=== 2. ... and use in another session with its own temporary table ==='
\c
SET gg_planman.log_usage = notice;
CREATE TEMP TABLE stage_orders AS
    SELECT * FROM orders WHERE order_date >= '2026-09-10' DISTRIBUTED BY (id);
CREATE INDEX stage_orders_amount_idx ON stage_orders (amount);
ANALYZE stage_orders;
EXPLAIN (COSTS off)
SELECT count(*) FROM stage_orders s JOIN customers c ON c.id = s.customer_id WHERE s.amount > 995;

\echo '=== 3.1 does the plan name segments? ==='
SELECT optimizer, direct_dispatch, segments
  FROM gg_planman.plan_info('SELECT name FROM customers WHERE id = 42');
SELECT optimizer, direct_dispatch, segments
  FROM gg_planman.plan_info('SELECT count(*) FROM orders WHERE amount > 990');

\echo '=== 3.2 a table matched by name: the load recreates orders, and the hints stay in use without regeneration ==='
SELECT * FROM gg_planman.register_hints($q$
    SELECT c.region, count(*)
      FROM customers c JOIN orders o ON o.customer_id = c.id
     WHERE o.order_date >= '2026-09-01' AND o.amount > 900
     GROUP BY c.region
$q$, 'SeqScan(o)', by_name => '{orders}');
CREATE TABLE orders_new (LIKE orders) DISTRIBUTED BY (id);
INSERT INTO orders_new SELECT * FROM orders;
DROP TABLE orders;
ALTER TABLE orders_new RENAME TO orders;
CREATE INDEX orders_customer_id_idx ON orders (customer_id);
CREATE INDEX orders_order_date_idx ON orders (order_date);
ANALYZE orders;
SELECT hints, rules FROM gg_planman.plans WHERE rules @> ARRAY['name'] ORDER BY created_at;
EXPLAIN (COSTS off)
SELECT c.region, count(*)
  FROM customers c JOIN orders o ON o.customer_id = c.id
 WHERE o.order_date >= '2026-09-02' AND o.amount > 900
 GROUP BY c.region;

\echo '=== 3.3 tables matched by a regular expression: one row for every yearly table ==='
CREATE TABLE orders_2025 (LIKE orders) DISTRIBUTED BY (id);
CREATE TABLE orders_2026 (LIKE orders) DISTRIBUTED BY (id);
INSERT INTO orders_2025 SELECT * FROM orders WHERE id % 2 = 0;
INSERT INTO orders_2026 SELECT * FROM orders WHERE id % 2 = 1;
ANALYZE orders_2025;
ANALYZE orders_2026;
SELECT * FROM gg_planman.register_hints('SELECT count(*) FROM orders_2026 o WHERE o.amount > 990', 'SeqScan(o)', by_regex => '{^public\\.orders_}');
EXPLAIN (COSTS off) SELECT count(*) FROM orders_2025 o WHERE o.amount > 995;
SELECT rules, patterns FROM gg_planman.plans WHERE 'orders_2026' = ANY(relnames);

\set QUIET on
DROP TABLE orders_2025, orders_2026;
\set QUIET off
