/* gg_planman/init.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION gg_planman" to load this file. \quit

/*
 * PoC of plan management for Greengage 7: stored hints.
 *
 * A row of gg_planman.plans holds the pg_hint_plan hints stored for a query.
 * The query is identified by two keys computed from its query tree:
 *   - key_base ignores constant values and the identity of the relations,
 *     keeping their aliases, which the hints address;
 *   - key_oid is key_base folded with the OIDs of all relations of the query;
 *     it is set only when the row matches every relation by OID.
 *
 * The relations of the query are its slots, in the order of the tree walk:
 * relschemas, relnames, reloids, rules and patterns are parallel arrays with
 * one element per slot.  The rule of a slot says how a relation of an
 * incoming query has to match it: 'oid', 'name' (the name in any schema),
 * 'schema.name', or 'regex' (the pattern matched against schema.name).
 * The rules come from the by_name and by_regex arguments of the registration,
 * kept in the row for regeneration.  n_oid, n_name and n_regex count the
 * slots of each kind and order the candidates of a lookup.
 *
 * Lookup: the row with the key_oid of the query, if any; otherwise, among the
 * rows with its key_base, the matching row with the most slots by OID, then
 * by name, then by regular expression, then the newest one.
 *
 * reloids and funcoids are the objects the query depends on.  The service
 * function check() reports a row invalid, with the reason, when one of them
 * was dropped or replaced or when the key of the stored text changed; the
 * store records nothing of it, and check(regenerate => true) registers such
 * rows again through regenerate_row(), keeping their ids.  There are no
 * event triggers.
 */
CREATE SCHEMA gg_planman;
GRANT USAGE ON SCHEMA gg_planman TO PUBLIC;

CREATE SEQUENCE gg_planman.plans_id_seq;

CREATE TABLE gg_planman.plans (
	id			bigint		NOT NULL DEFAULT nextval('gg_planman.plans_id_seq') PRIMARY KEY,
	key_base	bigint		NOT NULL,
	key_oid		bigint,
	enabled		boolean		NOT NULL,
	hints		text		NOT NULL,
	query		text		NOT NULL,
	paramtypes	regtype[],
	relschemas	text[],
	relnames	text[],
	reloids		oid[],
	rules		text[],
	patterns	text[],
	n_oid		int			NOT NULL,
	n_name		int			NOT NULL,
	n_regex		int			NOT NULL,
	identity	text		NOT NULL,
	by_name		text[],
	by_regex	text[],
	funcoids	oid[],
	created_at	timestamptz	NOT NULL
);

-- Keep the table on the coordinator only, as the sr_plan port did.
SET allow_system_table_mods = true;
DELETE FROM gp_distribution_policy WHERE localoid = 'gg_planman.plans'::regclass;
SET allow_system_table_mods = false;

CREATE INDEX plans_key_idx ON gg_planman.plans (key_base, key_oid);

/*
 * register_hints: store hints for a query.
 *
 * by_name lists relations matched by name instead of OID: 'name' matches the
 * name in any schema, 'schema.name' that schema, and '~regex' selects every
 * relation of the query whose schema.name matches the regular expression and
 * matches each of them by its exact schema and name.  by_regex lists regular
 * expressions; a relation whose schema.name matches one is matched at lookup
 * time by the expression itself, so that other relations match too.
 * A temporary table has to be covered by one of them.
 */
CREATE FUNCTION gg_planman.register_hints(query text,
										  hints text,
										  paramtypes regtype[] DEFAULT NULL,
										  by_name text[] DEFAULT NULL,
										  by_regex text[] DEFAULT NULL,
										  OUT id bigint,
										  OUT key_base bigint,
										  OUT key_oid bigint,
										  OUT slots text[])
RETURNS record
AS 'MODULE_PATHNAME', 'pm_register_hints'
LANGUAGE C CALLED ON NULL INPUT VOLATILE;

/* query_key: the keys and the slots of a query text, nothing is stored */
CREATE FUNCTION gg_planman.query_key(query text,
									 paramtypes regtype[] DEFAULT NULL,
									 by_name text[] DEFAULT NULL,
									 by_regex text[] DEFAULT NULL,
									 OUT id bigint,
									 OUT key_base bigint,
									 OUT key_oid bigint,
									 OUT slots text[])
RETURNS record
AS 'MODULE_PATHNAME', 'pm_query_key'
LANGUAGE C CALLED ON NULL INPUT VOLATILE;

/*
 * regenerate_row: register the row with this id again from its stored text,
 * hints, parameter types, by_name and by_regex; the row keeps its id.  The
 * service check calls it for every row it finds invalid.
 */
CREATE FUNCTION gg_planman.regenerate_row(row_id bigint,
										  OUT id bigint,
										  OUT key_base bigint,
										  OUT key_oid bigint,
										  OUT slots text[])
RETURNS record
AS 'MODULE_PATHNAME', 'pm_regenerate_row'
LANGUAGE C STRICT VOLATILE;

/* plan_info: what the optimizer puts into the plan of a query */
CREATE FUNCTION gg_planman.plan_info(query text,
									 paramtypes regtype[] DEFAULT NULL,
									 OUT optimizer text,
									 OUT slices int,
									 OUT direct_dispatch boolean,
									 OUT segments int[])
RETURNS record
AS 'MODULE_PATHNAME', 'pm_plan_info'
LANGUAGE C CALLED ON NULL INPUT VOLATILE;

/*
 * Service check of the store.
 *
 * For every row, in this order: a slot matched by OID whose relation no
 * longer exists or now belongs to a relation of another name, a function the
 * query calls that no longer exists, or a key_base that differs from the one
 * computed from the stored text makes the row invalid, and the first reason
 * found is reported.  A row that matches its dropped or recreated table by
 * name or by a regular expression is valid.  The check writes nothing: the
 * store records no result of it, and every call examines every row again.
 * With regenerate, every row found invalid is registered again from its
 * stored text, hints, parameter types, by_name and by_regex, keeping its id;
 * a row that cannot be registered is left as it is and reported with the
 * error as the reason.  With row_id only the row with that id is examined and
 * regenerated; an id without a row is an error.
 *
 * Any role with SELECT on the store runs the check under its own privileges;
 * regenerate needs a superuser.  A text the caller cannot resolve because it
 * has no USAGE on a schema leaves the key of that row unchecked.
 *
 * state: valid | invalid | regenerated | still_invalid
 */
CREATE FUNCTION gg_planman.check(regenerate boolean DEFAULT false, row_id bigint DEFAULT NULL)
RETURNS TABLE (id bigint, key_base bigint, identity text, state text, reason text)
LANGUAGE plpgsql AS $$
DECLARE
	r		record;
	rel		record;
	k		record;
	i		int;
	why		text;
BEGIN
	IF regenerate AND NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user) THEN
		RAISE EXCEPTION 'must be superuser to regenerate stored hints';
	END IF;
	IF row_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM gg_planman.plans p WHERE p.id = row_id) THEN
		RAISE EXCEPTION 'no stored row with id %', row_id;
	END IF;

	FOR r IN SELECT p.id, p.key_base, p.identity, p.query, p.paramtypes, p.by_name, p.by_regex,
					p.relschemas, p.relnames, p.reloids, p.rules, p.funcoids
			   FROM gg_planman.plans p
			  WHERE row_id IS NULL OR p.id = row_id
			  ORDER BY p.created_at, p.id
	LOOP
		why := NULL;
		id := r.id;
		key_base := r.key_base;
		identity := r.identity;

		/* the relations matched by OID */
		FOR i IN 1 .. coalesce(array_length(r.rules, 1), 0) LOOP
			CONTINUE WHEN r.rules[i] <> 'oid';
			SELECT n.nspname, c.relname INTO rel
			  FROM pg_catalog.pg_class c
			  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
			 WHERE c.oid = r.reloids[i];
			IF NOT FOUND THEN
				IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c
						   JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
						   WHERE n.nspname = r.relschemas[i] AND c.relname = r.relnames[i]) THEN
					why := format('table %I.%I was recreated', r.relschemas[i], r.relnames[i]);
				ELSE
					why := format('table %I.%I was dropped', r.relschemas[i], r.relnames[i]);
				END IF;
			ELSIF rel.nspname <> r.relschemas[i] OR rel.relname <> r.relnames[i] THEN
				why := format('table %I.%I is now %I.%I', r.relschemas[i], r.relnames[i],
							  rel.nspname, rel.relname);
			END IF;
			EXIT WHEN why IS NOT NULL;
		END LOOP;

		/* the functions the query calls */
		IF why IS NULL THEN
			FOR i IN 1 .. coalesce(array_length(r.funcoids, 1), 0) LOOP
				IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = r.funcoids[i]) THEN
					why := format('function with OID %s was dropped or replaced', r.funcoids[i]);
					EXIT;
				END IF;
			END LOOP;
		END IF;

		/* the key of the stored text, resolved with the search_path of this session */
		IF why IS NULL THEN
			BEGIN
				SELECT * INTO k FROM gg_planman.query_key(r.query, r.paramtypes, r.by_name, r.by_regex);
				IF k.key_base <> r.key_base THEN
					why := 'key changed';
				END IF;
			EXCEPTION WHEN undefined_table THEN
				IF EXISTS (SELECT 1 FROM unnest(r.rules) u WHERE u <> 'oid') THEN
					/* a table matched by name or by pattern, for example a temporary table of another session */
					state := 'valid';
					reason := 'a table matched by name or by pattern is not visible in this session, key not checked';
					RETURN NEXT;
					CONTINUE;
				END IF;
				why := SQLERRM;
			WHEN insufficient_privilege THEN
				/* a schema of the text the caller has no USAGE on: the slots were examined, the key was not */
				state := 'valid';
				reason := 'key not checked: ' || SQLERRM;
				RETURN NEXT;
				CONTINUE;
			WHEN OTHERS THEN
				why := SQLERRM;
			END;
		END IF;

		IF why IS NULL THEN
			state := 'valid';
			reason := NULL;
		ELSIF NOT regenerate THEN
			state := 'invalid';
			reason := why;
		ELSE
			BEGIN
				PERFORM gg_planman.regenerate_row(r.id);
				state := 'regenerated';
				reason := why;
			EXCEPTION WHEN OTHERS THEN
				state := 'still_invalid';
				reason := SQLERRM;
			END;
		END IF;
		RETURN NEXT;
	END LOOP;
END
$$;
