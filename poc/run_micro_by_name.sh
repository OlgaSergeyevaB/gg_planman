#!/bin/bash
# Planning-only cost when the store holds rows matched by name: EXPLAIN in a loop inside one backend
source /usr/local/gpdb7/greengage_path.sh
export PGPORT=7300 PGDATABASE=srpoc
OUT=results/27_planning_micro_by_name.txt
: > $OUT
P='SELECT pad FROM t1 WHERE id = $i'
J='SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v = $i'
psql -X -q -f 14_planning_micro.sql > /dev/null
fill() { # 10 000 unrelated rows, the first $1 of them match one table by name, the rest by OID
  psql -X -q -At -c "TRUNCATE gg_planman.plans" -c "INSERT INTO gg_planman.plans (key_base, key_oid, enabled, hints, query, relschemas, relnames, reloids, rules, patterns, n_oid, n_name, n_regex, identity, created_at, invalid) SELECT k, CASE WHEN i <= $1 THEN NULL ELSE k END, true, 'SeqScan(x)', 'dummy', ARRAY['public'], ARRAY['dummy_' || i], ARRAY[NULL::oid], ARRAY[CASE WHEN i <= $1 THEN 'schema.name' ELSE 'oid' END], ARRAY[NULL::text], CASE WHEN i <= $1 THEN 0 ELSE 1 END, CASE WHEN i <= $1 THEN 1 ELSE 0 END, 0, 'dummy:' || i, now(), false FROM (SELECT i, (random()*9e18)::bigint AS k FROM generate_series(1, 10000) i) s"
}
m() { # label enabled query
  for rep in 1 2 3; do
    v=$(psql -X -q -At -c "SET optimizer=off" -c "SET gg_planman.enabled=$2" -c "SELECT plan_loop(20000, \$q\$$3\$q\$)" | tail -1)
    printf "%-34s enabled=%-3s rep=%d us_per_plan=%s\n" "$1" $2 $rep "$v" >> $OUT
  done
}
fill 0
m "point base"                  off "$P"
m "point miss, no names"        on  "$P"
m "join base"                   off "$J"
m "join miss, no names"         on  "$J"
fill 200
m "point miss, 200 names"       on  "$P"
m "join miss, 200 names"        on  "$J"
psql -X -q -At -c "SELECT gg_planman.register_hints('SELECT pad FROM t1 WHERE id = 1', 'SeqScan(t1)')" -c "SELECT gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v = 1', 'SeqScan(t2) BitmapScan(t1 t1_v_idx) HashJoin(t1 t2)')" > /dev/null
m "point hit by OID, 200 names" on  "$P"
m "join hit by OID, 200 names"  on  "$J"
fill 200
psql -X -q -At -c "SELECT gg_planman.register_hints('SELECT pad FROM t1 WHERE id = 1', 'SeqScan(t1)', by_name => '{t1}')" -c "SELECT gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v = 1', 'SeqScan(t2) BitmapScan(t1 t1_v_idx) HashJoin(t1 t2)', by_name => '{t1,t2}')" > /dev/null
psql -X -q -At -c "SELECT 'rows matched by name: ' || count(*) FILTER (WHERE key_oid IS NULL) || ', rules of t1 and t2 rows: ' || string_agg(DISTINCT rules::text, ' ') FILTER (WHERE query <> 'dummy') FROM gg_planman.plans" >> $OUT
m "point hit by name, 202 names" on "$P"
m "join hit by name, 202 names" on  "$J"
psql -X -q -At -c "TRUNCATE gg_planman.plans"
echo done >> $OUT
