#!/bin/bash
# Overhead of gg_planman lookups: pgbench, simple protocol, so every execution is planned.
source /usr/local/gpdb7/greengage_path.sh
export PGPORT=7300 PGDATABASE=srpoc
OUT=results/13_overhead.txt
DUR=15
: > $OUT
sql() { psql -X -q -At -c "$1"; }

# Background rows so that lookups go through a populated index
sql "TRUNCATE gg_planman.plans"
sql "INSERT INTO gg_planman.plans (key_base, key_oid, enabled, hints, query, n_oid, n_name, n_regex, identity, created_at, invalid) SELECT k, k, true, 'SeqScan(x)', 'dummy', 1, 0, 0, 'oid:0', now(), false FROM (SELECT (random()*9e18)::bigint AS k FROM generate_series(1, 10000)) s"
sql "ANALYZE gg_planman.plans"
echo "plans rows: $(sql 'SELECT count(*) FROM gg_planman.plans')" >> $OUT

run() { # label script optimizer enabled
  for rep in 1 2; do
    res=$(PGOPTIONS="-c optimizer=$3 -c gg_planman.enabled=$4" \
          pgbench -n -M simple -c 8 -j 8 -T $DUR -f $2 2>&1)
    tps=$(echo "$res" | grep -oP 'tps = \K[0-9.]+' | head -1)
    lat=$(echo "$res" | grep -oP 'latency average = \K[0-9.]+')
    printf "%-10s %-6s optimizer=%-3s enabled=%-3s rep=%d tps=%s latency_ms=%s\n" "$1" "$(basename $2 .sql | sed 's/bench_//')" $3 $4 $rep "$tps" "$lat" >> $OUT
  done
}

for opt in off on; do
  run base bench_point.sql $opt off
  run miss bench_point.sql $opt on
  run base bench_join.sql  $opt off
  run miss bench_join.sql  $opt on
done

# Hits: hints that do not change the chosen plan
sql "SELECT gg_planman.register_hints('SELECT pad FROM t1 WHERE id = 1', 'SeqScan(t1)')" >/dev/null
sql "SELECT gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v = 1', 'SeqScan(t2) BitmapScan(t1 t1_v_idx) HashJoin(t1 t2)')" >/dev/null
run hit bench_point.sql off on
run hit bench_join.sql  off on
sql "SELECT gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v = 1', 'IndexScan(t1 t1_v_idx) IndexScan(t2 t2_t1_id_idx)')" >/dev/null
run hit bench_point.sql on on
run hit bench_join.sql  on on
sql "TRUNCATE gg_planman.plans"
echo done >> $OUT
