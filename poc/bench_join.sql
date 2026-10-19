\set v random(0, 9999)
SELECT count(*) FROM t1 JOIN t2 ON t1.id = t2.t1_id WHERE t1.v = :v;
