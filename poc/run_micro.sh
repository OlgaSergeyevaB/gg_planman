#!/bin/bash
# Planning-only cost: EXPLAIN in a loop inside one backend, no execution and no dispatch
source /usr/local/gpdb7/greengage_path.sh
export PGPORT=7300 PGDATABASE=srpoc
OUT=results/14_planning_micro.txt
: > $OUT
P='SELECT pad FROM t1 WHERE id = $i'
J='SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v = $i'
psql -X -q -f 14_planning_micro.sql > /dev/null
psql -X -q -At -c "TRUNCATE gg_planman.plans" -c "INSERT INTO gg_planman.plans (key_base, key_oid, enabled, hints, query, n_oid, n_name, n_regex, identity, created_at, invalid) SELECT k, k, true, 'SeqScan(x)', 'dummy', 1, 0, 0, 'oid:0', now(), false FROM (SELECT (random()*9e18)::bigint AS k FROM generate_series(1, 10000)) s"
m() { # label optimizer enabled query
  local n=20000
  [ "$2" = on ] && n=2000
  for rep in 1 2 3; do
    v=$(psql -X -q -At -c "SET optimizer=$2" -c "SET gg_planman.enabled=$3" -c "SELECT plan_loop($n, \$q\$$4\$q\$)" | tail -1)
    printf "%-12s optimizer=%-3s enabled=%-3s n=%-5d rep=%d us_per_plan=%s\n" "$1" $2 $3 $n $rep "$v" >> $OUT
  done
}
for opt in off on; do
  m "point base" $opt off "$P"
  m "point miss" $opt on  "$P"
  m "join base"  $opt off "$J"
  m "join miss"  $opt on  "$J"
done
psql -X -q -At -c "SELECT gg_planman.register_hints('SELECT pad FROM t1 WHERE id = 1', 'SeqScan(t1)')" -c "SELECT gg_planman.register_hints('SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v = 1', 'SeqScan(t2) BitmapScan(t1 t1_v_idx) HashJoin(t1 t2)')" > /dev/null
for opt in off on; do
  m "point hit" $opt on "$P"
  m "join hit"  $opt on "$J"
done
psql -X -q -At -c "TRUNCATE gg_planman.plans"
echo done >> $OUT
