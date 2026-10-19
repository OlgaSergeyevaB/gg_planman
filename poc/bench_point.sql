\set id random(1, 200000)
SELECT pad FROM t1 WHERE id = :id;
