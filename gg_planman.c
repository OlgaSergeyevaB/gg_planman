/*
 * gg_planman.c
 *		Plan management for Greengage 7, proof of concept: stored hints.
 *
 * A stored row holds a pg_hint_plan hint string for a query.  The query is
 * identified by two 64-bit keys computed from its query tree with core
 * JumbleQuery():
 *   - key_base is the jumble of the tree with the identity of every relation
 *     replaced by its alias, so constant values and the relations themselves
 *     do not take part, while the aliases, which hints address, do;
 *   - key_oid is key_base folded with the OIDs of all relations of the query
 *     in the order of the tree walk.
 *
 * The relations of the query are its slots, in that order.  A row keeps, per
 * slot, the schema, the name, the OID and the rule a relation of an incoming
 * query has to satisfy: the same OID, the same name in any schema, the same
 * schema and name, or a regular expression matched against schema.name.  The
 * rules come from the by_name and by_regex arguments of the registration;
 * without them every slot is matched by OID and the row has a key_oid.
 *
 * Lookup: the row with the key_oid of the query is applied as is.  Otherwise
 * every row with its key_base is checked slot by slot, and the most specific
 * matching row is applied: the most slots by OID, then by name, then by
 * regular expression, then the newest row.
 *
 * The query is planned as usual with its actual constants, and the hint
 * string is handed to pg_hint_plan, which has to be loaded before gg_planman
 * and is not patched.  Hints written in the text of the query itself win over
 * the hints stored for it.  In write mode the hint comment of the statement
 * the client sent is stored for the query; an EXPLAIN, which the DBA uses to
 * try hints without storing them, and any other text the registration would
 * refuse are not stored, and a warning says why.
 *
 * A row keeps the relations and the user-defined functions its query depends
 * on.  The service function check() of the extension script reports the row
 * invalid, with the reason, when one of them was dropped or replaced, unless
 * the row matches the relation by name, or when the key of the stored text
 * changed.  The store records nothing of it: such a row is not applied
 * because its slots or its keys no longer match the query, and the check
 * with regenerate registers it again through regenerate_row(), which keeps
 * its id.  A disabled row is not applied.
 */
#include "postgres.h"

#include "commands/sequence.h"

#include <ctype.h>

#include "access/genam.h"
#include "access/heapam.h"
#include "access/hash.h"
#include "access/htup_details.h"
#include "access/relscan.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/transam.h"
#include "access/xact.h"
#include "catalog/index.h"
#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/pg_collation.h"
#include "catalog/pg_type.h"
#include "common/hashfn.h"
#include "commands/extension.h"
#include "executor/tuptable.h"
#include "fmgr.h"
#include "funcapi.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "nodes/nodeFuncs.h"
#include "optimizer/planner.h"
#include "parser/analyze.h"
#include "parser/parse_node.h"
#include "regex/regex.h"
#include "storage/lmgr.h"
#include "tcop/tcopprot.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/guc.h"
#include "utils/inval.h"
#include "utils/lsyscache.h"
#include "utils/queryjumble.h"
#include "utils/regproc.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"

#include "gg_planman.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(pm_register_hints);
PG_FUNCTION_INFO_V1(pm_regenerate_row);
PG_FUNCTION_INFO_V1(pm_query_key);
PG_FUNCTION_INFO_V1(pm_plan_info);

void		_PG_init(void);

static const struct config_enum_entry log_usage_options[] = {
	{"none", 0, false},
	{"debug", DEBUG2, true},
	{"debug5", DEBUG5, false},
	{"debug4", DEBUG4, false},
	{"debug3", DEBUG3, false},
	{"debug2", DEBUG2, false},
	{"debug1", DEBUG1, false},
	{"log", LOG, false},
	{"info", INFO, true},
	{"notice", NOTICE, false},
	{"warning", WARNING, false},
	{NULL, 0, false}
};

/* GUCs */
static bool pm_enabled = true;
static bool pm_write_mode = false;

/* The by_name selector that the capture applies to temporary tables */
#define PM_TEMP_SELECTOR "~^pg_temp\\."
static int	pm_log_usage = 0;

/* Hooks */
static planner_hook_type prev_planner_hook = NULL;

/*
 * post_parse_analyze_hook as it was when gg_planman got loaded, that is the
 * pg_hint_plan one if pg_hint_plan is listed before gg_planman.  gg_planman
 * does not install a hook of its own there; it only calls this one to make
 * pg_hint_plan read a hint string.
 */
static post_parse_analyze_hook_type hint_analyze_hook = NULL;

/* OIDs of the plan store, reset by relcache invalidation */
typedef struct PmCatalog
{
	Oid			plans_rel;
	Oid			key_idx;
	Oid			pkey_idx;
	Oid			id_seq;
} PmCatalog;

static PmCatalog pm_catalog = {InvalidOid, InvalidOid};

/*
 * The OIDs the current operation works with.  A relcache invalidation that
 * arrives while the operation holds the store open resets pm_catalog, so the
 * operation keeps the copy it took when it started.
 */
static PmCatalog pm_use = {InvalidOid, InvalidOid, InvalidOid, InvalidOid};

/* How a relation of an incoming query has to match a slot of a stored row */
typedef enum PmRule
{
	PM_RULE_OID = 0,
	PM_RULE_NAME,				/* the name in any schema */
	PM_RULE_SCHEMA_NAME,
	PM_RULE_REGEX				/* a regular expression over schema.name */
} PmRule;

static const char *const pm_rule_names[] = {"oid", "name", "schema.name", "regex"};

/* A relation of a query in the order of the tree walk */
typedef struct PmSlot
{
	Oid			relid;
	char	   *schema;			/* pg_temp for a temporary table */
	char	   *relname;
	bool		is_temp;
	PmRule		rule;
	char	   *pattern;		/* the regular expression of a regex slot */
} PmSlot;

/* The keys of a query, plus what computing them resolved */
typedef struct PmKey
{
	int64		key_base;
	int64		key_oid;
	bool		has_key_oid;	/* every slot is matched by OID */
	List	   *slots;			/* PmSlot * */
	List	   *funcoids;		/* Oid of user-defined functions */
} PmKey;

/* Relation OIDs temporarily replaced with alias hashes in a query tree */
typedef struct PmWalk
{
	List	   *rtes;
	List	   *relids;
	List	   *slots;
	List	   *funcoids;
} PmWalk;

/* An entry of by_name or by_regex */
typedef struct PmSpec
{
	char	   *text;			/* as given */
	char	   *schema;			/* exact entries, NULL when unqualified */
	char	   *relname;
	char	   *pattern;		/* selectors of by_name and entries of by_regex */
	bool		selector;		/* a '~regex' entry of by_name */
	bool		used;
} PmSpec;

static int	planner_nesting_level = 0;

static PlannedStmt *pm_planner(Query *parse, int cursorOptions,
							   ParamListInfo boundParams);

/*
 * Catalog access
 */

static void
pm_relcache_callback(Datum arg, Oid relid)
{
	if (relid == InvalidOid || relid == pm_catalog.plans_rel)
	{
		pm_catalog.plans_rel = InvalidOid;
		pm_catalog.key_idx = InvalidOid;
		pm_catalog.pkey_idx = InvalidOid;
		pm_catalog.id_seq = InvalidOid;
	}
}

static bool
pm_catalog_ready(void)
{
	static bool callback_registered = false;
	Oid			schema;

	if (OidIsValid(pm_catalog.plans_rel))
	{
		pm_use = pm_catalog;
		return true;
	}

	if (!IsTransactionState())
		return false;

	if (!OidIsValid(get_extension_oid(PM_EXTENSION_NAME, true)))
		return false;

	schema = get_namespace_oid(PM_SCHEMA_NAME, true);
	if (!OidIsValid(schema))
		return false;

	pm_catalog.plans_rel = get_relname_relid(PM_PLANS_TABLE, schema);
	pm_catalog.key_idx = get_relname_relid(PM_PLANS_KEY_INDEX, schema);
	pm_catalog.pkey_idx = get_relname_relid(PM_PLANS_PKEY_INDEX, schema);
	pm_catalog.id_seq = get_relname_relid(PM_PLANS_ID_SEQ, schema);

	if (!OidIsValid(pm_catalog.plans_rel) || !OidIsValid(pm_catalog.key_idx) ||
		!OidIsValid(pm_catalog.pkey_idx) || !OidIsValid(pm_catalog.id_seq))
	{
		pm_relcache_callback((Datum) 0, InvalidOid);
		return false;
	}

	if (!callback_registered)
	{
		CacheRegisterRelcacheCallback(pm_relcache_callback, (Datum) 0);
		callback_registered = true;
	}

	pm_use = pm_catalog;
	return true;
}

/*
 * Arrays
 */

static Datum
pm_array(Datum *elems, bool *nulls, int n, Oid elmtype, int elmlen,
		 bool elmbyval, char elmalign)
{
	int			dims[1];
	int			lbs[1];

	if (n == 0)
		return PointerGetDatum(construct_empty_array(elmtype));

	dims[0] = n;
	lbs[0] = 1;
	return PointerGetDatum(construct_md_array(elems, nulls, 1, dims, lbs,
											  elmtype, elmlen, elmbyval, elmalign));
}

static Datum
pm_oid_array(List *oids)
{
	Datum	   *elems;
	ListCell   *lc;
	int			i = 0;

	elems = palloc(sizeof(Datum) * (list_length(oids) + 1));
	foreach(lc, oids)
		elems[i++] = ObjectIdGetDatum(lfirst_oid(lc));

	return pm_array(elems, NULL, i, OIDOID, sizeof(Oid), true, 'i');
}

/* The per-slot columns of a row */
static void
pm_slot_arrays(const PmKey *key, Datum *values, bool *nulls)
{
	int			n = list_length(key->slots);
	Datum	   *schemas = palloc(sizeof(Datum) * (n + 1));
	Datum	   *names = palloc(sizeof(Datum) * (n + 1));
	Datum	   *oids = palloc(sizeof(Datum) * (n + 1));
	bool	   *oid_nulls = palloc(sizeof(bool) * (n + 1));
	Datum	   *rules = palloc(sizeof(Datum) * (n + 1));
	Datum	   *patterns = palloc(sizeof(Datum) * (n + 1));
	bool	   *pattern_nulls = palloc(sizeof(bool) * (n + 1));
	ListCell   *lc;
	int			i = 0;

	foreach(lc, key->slots)
	{
		PmSlot	   *slot = (PmSlot *) lfirst(lc);

		schemas[i] = CStringGetTextDatum(slot->schema);
		names[i] = CStringGetTextDatum(slot->relname);
		oids[i] = ObjectIdGetDatum(slot->relid);
		oid_nulls[i] = slot->is_temp;
		rules[i] = CStringGetTextDatum(pm_rule_names[slot->rule]);
		patterns[i] = slot->pattern ? CStringGetTextDatum(slot->pattern) : (Datum) 0;
		pattern_nulls[i] = (slot->pattern == NULL);
		i++;
	}

	values[Anum_plans_relschemas - 1] = pm_array(schemas, NULL, n, TEXTOID, -1, false, 'i');
	values[Anum_plans_relnames - 1] = pm_array(names, NULL, n, TEXTOID, -1, false, 'i');
	values[Anum_plans_reloids - 1] = pm_array(oids, oid_nulls, n, OIDOID, sizeof(Oid), true, 'i');
	values[Anum_plans_rules - 1] = pm_array(rules, NULL, n, TEXTOID, -1, false, 'i');
	values[Anum_plans_patterns - 1] = pm_array(patterns, pattern_nulls, n, TEXTOID, -1, false, 'i');
	nulls[Anum_plans_relschemas - 1] = false;
	nulls[Anum_plans_relnames - 1] = false;
	nulls[Anum_plans_reloids - 1] = false;
	nulls[Anum_plans_rules - 1] = false;
	nulls[Anum_plans_patterns - 1] = false;
}

/*
 * Query keys
 */

static bool
pm_walker(Node *node, PmWalk *walk)
{
	if (node == NULL)
		return false;

	if (IsA(node, RangeTblEntry))
	{
		RangeTblEntry *rte = (RangeTblEntry *) node;
		Oid			namespace;
		char	   *relname;
		const char *alias;
		PmSlot	   *slot;

		if (rte->rtekind != RTE_RELATION || !OidIsValid(rte->relid))
			return false;

		namespace = get_rel_namespace(rte->relid);
		relname = get_rel_name(rte->relid);
		if (!OidIsValid(namespace) || relname == NULL)
			return false;

		slot = palloc0(sizeof(PmSlot));
		slot->relid = rte->relid;
		slot->is_temp = isAnyTempNamespace(namespace);
		slot->schema = slot->is_temp ? "pg_temp" : get_namespace_name(namespace);
		slot->relname = relname;
		slot->rule = PM_RULE_OID;

		walk->rtes = lappend(walk->rtes, rte);
		walk->relids = lappend_oid(walk->relids, rte->relid);
		walk->slots = lappend(walk->slots, slot);

		/*
		 * The alias stands in for the relation in the jumble: hints address
		 * relations by alias, so the same query with other aliases needs
		 * other hints.
		 */
		alias = (rte->eref != NULL && rte->eref->aliasname != NULL) ?
			rte->eref->aliasname : relname;
		rte->relid = (Oid) DatumGetUInt32(hash_any((const unsigned char *) alias,
												   strlen(alias)));
		return false;
	}

	{
		Oid			funcid = InvalidOid;

		if (IsA(node, FuncExpr))
			funcid = ((FuncExpr *) node)->funcid;
		else if (IsA(node, Aggref))
			funcid = ((Aggref *) node)->aggfnoid;
		else if (IsA(node, WindowFunc))
			funcid = ((WindowFunc *) node)->winfnoid;

		if (funcid >= FirstNormalObjectId)
			walk->funcoids = list_append_unique_oid(walk->funcoids, funcid);
	}

	if (IsA(node, Query))
		return query_tree_walker((Query *) node, pm_walker, (void *) walk,
								 QTW_EXAMINE_RTES_BEFORE);

	return expression_tree_walker(node, pm_walker, (void *) walk);
}

static void
pm_restore_relids(PmWalk *walk)
{
	ListCell   *lc_rte;
	ListCell   *lc_relid;

	forboth(lc_rte, walk->rtes, lc_relid, walk->relids)
		((RangeTblEntry *) lfirst(lc_rte))->relid = lfirst_oid(lc_relid);
}

/* JumbleQuery() without leaving its queryId in the tree */
static int64
pm_jumble_hash(Query *query)
{
	uint64		saved_query_id = query->queryId;
	uint64		result;

	(void) JumbleQuery(query);
	result = query->queryId;
	query->queryId = saved_query_id;

	return (int64) result;
}

/*
 * key_oid: key_base folded with the OIDs of the slots.  A temporary table
 * has another OID in every session, and a slot matched by name or by a
 * regular expression has no fixed OID, so such a query has no key_oid.
 */
static void
pm_fold_key_oid(PmKey *key)
{
	uint64		acc = (uint64) key->key_base;
	ListCell   *lc;

	key->has_key_oid = true;
	foreach(lc, key->slots)
	{
		PmSlot	   *slot = (PmSlot *) lfirst(lc);

		if (slot->is_temp || slot->rule != PM_RULE_OID)
		{
			key->has_key_oid = false;
			key->key_oid = 0;
			return;
		}
		acc = hash_combine64(acc, (uint64) slot->relid);
	}
	key->key_oid = (int64) acc;
}

/*
 * The keys of a query: core JumbleQuery() over the tree, with every relation
 * OID replaced by a hash of its alias for the duration of the call, gives
 * key_base; the slots and the user-defined functions of the query are
 * returned in key as well, and key_oid is folded from the slots.
 */
static void
pm_compute_key(Query *query, PmKey *key)
{
	PmWalk		walk;

	MemSet(key, 0, sizeof(PmKey));
	MemSet(&walk, 0, sizeof(PmWalk));

	PG_TRY();
	{
		pm_walker((Node *) query, &walk);
		key->key_base = pm_jumble_hash(query);
	}
	PG_CATCH();
	{
		pm_restore_relids(&walk);
		PG_RE_THROW();
	}
	PG_END_TRY();

	pm_restore_relids(&walk);
	key->slots = walk.slots;
	key->funcoids = walk.funcoids;
	pm_fold_key_oid(key);
}

/*
 * Rules of the slots
 */

static bool
pm_regex_matches(const char *pattern, const char *subject)
{
	return RE_compile_and_execute(cstring_to_text(pattern), (char *) subject,
								  strlen(subject), REG_ADVANCED,
								  C_COLLATION_OID, 0, NULL);
}

/* Turn a by_name or by_regex argument into its entries */
static List *
pm_parse_specs(ArrayType *array, bool regex_arg, const char *argname)
{
	List	   *result = NIL;
	Datum	   *elems;
	bool	   *elem_nulls;
	int			nelems;
	int			i;

	if (array == NULL)
		return NIL;

	deconstruct_array(array, TEXTOID, -1, false, 'i',
					  &elems, &elem_nulls, &nelems);
	for (i = 0; i < nelems; i++)
	{
		PmSpec	   *spec = palloc0(sizeof(PmSpec));

		if (elem_nulls[i])
			ereport(ERROR,
					(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
					 errmsg("%s must not contain NULL", argname)));

		spec->text = TextDatumGetCString(elems[i]);
		if (regex_arg || spec->text[0] == '~')
		{
			spec->selector = !regex_arg;
			spec->pattern = regex_arg ? spec->text : spec->text + 1;
			/* Compile it now, so that a bad pattern fails the registration */
			(void) pm_regex_matches(spec->pattern, "");
		}
		else
		{
			List	   *names = stringToQualifiedNameList(spec->text);

			switch (list_length(names))
			{
				case 1:
					spec->relname = strVal(linitial(names));
					break;
				case 2:
					spec->schema = strVal(linitial(names));
					spec->relname = strVal(lsecond(names));
					break;
				default:
					ereport(ERROR,
							(errcode(ERRCODE_SYNTAX_ERROR),
							 errmsg("improper relation name in %s: \"%s\"",
									argname, spec->text)));
			}
		}
		result = lappend(result, spec);
	}
	return result;
}

/*
 * Give every slot its rule.  An exact schema-qualified name wins over an
 * unqualified one, which wins over a selector of by_name, which wins over a
 * by_regex entry; a slot nothing covers is matched by OID.
 */
static void
pm_assign_rules(PmKey *key, List *by_name, List *by_regex)
{
	ListCell   *lc;
	ListCell   *lc2;

	foreach(lc, key->slots)
	{
		PmSlot	   *slot = (PmSlot *) lfirst(lc);
		char	   *full = psprintf("%s.%s", slot->schema, slot->relname);
		PmSpec	   *hit = NULL;

		foreach(lc2, by_name)
		{
			PmSpec	   *spec = (PmSpec *) lfirst(lc2);

			if (!spec->selector && spec->schema != NULL &&
				strcmp(spec->schema, slot->schema) == 0 &&
				strcmp(spec->relname, slot->relname) == 0)
			{
				hit = spec;
				slot->rule = PM_RULE_SCHEMA_NAME;
				break;
			}
		}
		if (hit == NULL)
		{
			foreach(lc2, by_name)
			{
				PmSpec	   *spec = (PmSpec *) lfirst(lc2);

				if (!spec->selector && spec->schema == NULL &&
					strcmp(spec->relname, slot->relname) == 0)
				{
					hit = spec;
					slot->rule = PM_RULE_NAME;
					break;
				}
			}
		}
		if (hit == NULL)
		{
			foreach(lc2, by_name)
			{
				PmSpec	   *spec = (PmSpec *) lfirst(lc2);

				if (spec->selector && pm_regex_matches(spec->pattern, full))
				{
					hit = spec;
					slot->rule = PM_RULE_SCHEMA_NAME;
					break;
				}
			}
		}
		if (hit == NULL)
		{
			foreach(lc2, by_regex)
			{
				PmSpec	   *spec = (PmSpec *) lfirst(lc2);

				if (pm_regex_matches(spec->pattern, full))
				{
					hit = spec;
					slot->rule = PM_RULE_REGEX;
					slot->pattern = spec->pattern;
					break;
				}
			}
		}

		if (hit != NULL)
			hit->used = true;
	}

	/* An entry that covers nothing is reported before a slot nothing covers */
	foreach(lc, by_name)
	{
		PmSpec	   *spec = (PmSpec *) lfirst(lc);

		if (spec->used)
			continue;
		if (!spec->selector)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("table \"%s\" listed in by_name is not read by the query",
							spec->text)));
		ereport(NOTICE,
				(errmsg("gg_planman: pattern \"%s\" of by_name selects no table of the query",
						spec->pattern)));
	}
	foreach(lc, by_regex)
	{
		PmSpec	   *spec = (PmSpec *) lfirst(lc);

		if (!spec->used)
			ereport(NOTICE,
					(errmsg("gg_planman: pattern \"%s\" of by_regex matches no table of the query",
							spec->pattern)));
	}

	foreach(lc, key->slots)
	{
		PmSlot	   *slot = (PmSlot *) lfirst(lc);

		if (slot->is_temp && slot->rule == PM_RULE_OID)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("temporary table \"%s\" can be identified only by name",
							slot->relname),
					 errhint("List it in by_name as pg_temp.%s or with a selector such as ~^pg_temp\\., or match it with by_regex, to confirm that the row applies to every temporary table of that name.",
							 slot->relname)));
	}

	pm_fold_key_oid(key);
}

static void
pm_slot_counts(const PmKey *key, int *n_oid, int *n_name, int *n_regex)
{
	ListCell   *lc;

	*n_oid = *n_name = *n_regex = 0;
	foreach(lc, key->slots)
	{
		PmSlot	   *slot = (PmSlot *) lfirst(lc);

		switch (slot->rule)
		{
			case PM_RULE_OID:
				(*n_oid)++;
				break;
			case PM_RULE_NAME:
			case PM_RULE_SCHEMA_NAME:
				(*n_name)++;
				break;
			case PM_RULE_REGEX:
				(*n_regex)++;
				break;
		}
	}
}

/*
 * What makes a row the row of a registration: the rule of every slot with
 * what it matches.  A registration replaces the row with the same key_base
 * and identity.
 */
static char *
pm_identity(const PmKey *key)
{
	StringInfoData buf;
	ListCell   *lc;

	initStringInfo(&buf);
	foreach(lc, key->slots)
	{
		PmSlot	   *slot = (PmSlot *) lfirst(lc);

		if (buf.len > 0)
			appendStringInfoChar(&buf, ' ');
		switch (slot->rule)
		{
			case PM_RULE_OID:
				appendStringInfo(&buf, "oid:%u", slot->relid);
				break;
			case PM_RULE_NAME:
				appendStringInfo(&buf, "name:%s", slot->relname);
				break;
			case PM_RULE_SCHEMA_NAME:
				appendStringInfo(&buf, "schema:%s.%s", slot->schema, slot->relname);
				break;
			case PM_RULE_REGEX:
				appendStringInfo(&buf, "regex:%s", slot->pattern);
				break;
		}
	}
	return buf.data;
}

/* The slots of a query for the DBA: schema.name=rule */
static Datum
pm_slots_text(const PmKey *key)
{
	int			n = list_length(key->slots);
	Datum	   *elems = palloc(sizeof(Datum) * (n + 1));
	ListCell   *lc;
	int			i = 0;

	foreach(lc, key->slots)
	{
		PmSlot	   *slot = (PmSlot *) lfirst(lc);
		char	   *s;

		if (slot->rule == PM_RULE_REGEX)
			s = psprintf("%s.%s=regex(%s)", slot->schema, slot->relname, slot->pattern);
		else
			s = psprintf("%s.%s=%s", slot->schema, slot->relname,
						 pm_rule_names[slot->rule]);
		elems[i++] = CStringGetTextDatum(s);
	}
	return pm_array(elems, NULL, n, TEXTOID, -1, false, 'i');
}

/*
 * Store
 */

/*
 * Store hints for a query.
 *
 * The new row replaces the row of the same registration, the one with the
 * same key_base and identity, and keeps its id.  A regeneration passes the id
 * of the row it registers again in replace_id: that row is replaced too,
 * whatever its identity is now, and the new row gets its id.
 *
 * ShareRowExclusiveLock serializes writers without blocking lookups, and it is
 * held until the end of the transaction: a writer that got the lock earlier
 * must not see the rows of an uncommitted one.
 */
static int64
pm_store_row(const PmKey *key, const char *query_text, const char *hints,
			 ArrayType *paramtypes, ArrayType *by_name, ArrayType *by_regex,
			 int64 replace_id)
{
	int64		id = 0;
	bool		has_id = false;
	Relation	heap;
	Relation	index;
	Relation	pkey;
	Snapshot	snapshot;
	TableScanDesc scan;
	TupleTableSlot *slot;
	HeapTuple	tuple;
	Datum		values[Natts_plans];
	bool		nulls[Natts_plans];
	char	   *identity = pm_identity(key);
	int			n_oid;
	int			n_name;
	int			n_regex;

	heap = table_open(pm_use.plans_rel, ShareRowExclusiveLock);
	index = index_open(pm_use.key_idx, RowExclusiveLock);
	pkey = index_open(pm_use.pkey_idx, RowExclusiveLock);

	snapshot = RegisterSnapshot(GetLatestSnapshot());
	slot = table_slot_create(heap, NULL);
	scan = table_beginscan(heap, snapshot, 0, NULL);
	while (table_scan_getnextslot(scan, ForwardScanDirection, slot))
	{
		bool		isnull;
		Datum		value;
		bool		same = false;
		int64		row_id;

		value = slot_getattr(slot, Anum_plans_id, &isnull);
		row_id = isnull ? 0 : DatumGetInt64(value);
		value = slot_getattr(slot, Anum_plans_key_base, &isnull);
		if (!isnull && DatumGetInt64(value) == key->key_base)
		{
			value = slot_getattr(slot, Anum_plans_identity, &isnull);
			same = !isnull && strcmp(TextDatumGetCString(value), identity) == 0;
		}
		if (!same && (replace_id == 0 || row_id != replace_id))
			continue;
		if (row_id != 0 && (!has_id || row_id == replace_id))
		{
			id = row_id;
			has_id = true;
		}
		simple_heap_delete(heap, &slot->tts_tid);
	}
	table_endscan(scan);
	ExecDropSingleTupleTableSlot(slot);
	UnregisterSnapshot(snapshot);

	pm_slot_counts(key, &n_oid, &n_name, &n_regex);

	if (!has_id)
		id = nextval_internal(pm_use.id_seq, false, false);

	MemSet(nulls, false, sizeof(nulls));
	values[Anum_plans_id - 1] = Int64GetDatum(id);
	values[Anum_plans_key_base - 1] = Int64GetDatum(key->key_base);
	values[Anum_plans_key_oid - 1] = Int64GetDatum(key->key_oid);
	nulls[Anum_plans_key_oid - 1] = !key->has_key_oid;
	values[Anum_plans_enabled - 1] = BoolGetDatum(true);
	values[Anum_plans_hints - 1] = CStringGetTextDatum(hints);
	values[Anum_plans_query - 1] = CStringGetTextDatum(query_text);
	values[Anum_plans_paramtypes - 1] = PointerGetDatum(paramtypes);
	nulls[Anum_plans_paramtypes - 1] = (paramtypes == NULL);
	pm_slot_arrays(key, values, nulls);
	values[Anum_plans_n_oid - 1] = Int32GetDatum(n_oid);
	values[Anum_plans_n_name - 1] = Int32GetDatum(n_name);
	values[Anum_plans_n_regex - 1] = Int32GetDatum(n_regex);
	values[Anum_plans_identity - 1] = CStringGetTextDatum(identity);
	values[Anum_plans_by_name - 1] = PointerGetDatum(by_name);
	nulls[Anum_plans_by_name - 1] = (by_name == NULL);
	values[Anum_plans_by_regex - 1] = PointerGetDatum(by_regex);
	nulls[Anum_plans_by_regex - 1] = (by_regex == NULL);
	values[Anum_plans_funcoids - 1] = pm_oid_array(key->funcoids);
	values[Anum_plans_created_at - 1] =
		TimestampTzGetDatum(GetCurrentTimestamp());

	tuple = heap_form_tuple(RelationGetDescr(heap), values, nulls);
	simple_heap_insert(heap, tuple);
	index_insert(index, &values[Anum_plans_key_base - 1],
				 &nulls[Anum_plans_key_base - 1], &tuple->t_self, heap,
				 UNIQUE_CHECK_NO, BuildIndexInfo(index));
	index_insert(pkey, &values[Anum_plans_id - 1], &nulls[Anum_plans_id - 1],
				 &tuple->t_self, heap, UNIQUE_CHECK_YES, BuildIndexInfo(pkey));

	index_close(pkey, NoLock);
	index_close(index, NoLock);
	table_close(heap, NoLock);

	CommandCounterIncrement();
	return id;
}

/*
 * Lookup
 */

/*
 * Does every slot of the row accept the relation of the query in that slot?
 * replaced_table is set to schema.name when a slot matched by OID holds
 * another OID for a relation of the same schema and name: the table was
 * recreated under its name.
 */
static bool
pm_row_matches(TupleTableSlot *tslot, const PmKey *key, const char **replaced_table)
{
	Datum		value;
	bool		isnull;
	Datum	   *schemas;
	Datum	   *names;
	Datum	   *oids;
	bool	   *oid_nulls;
	Datum	   *rules;
	Datum	   *patterns;
	bool	   *pattern_nulls;
	int			nschemas;
	int			nnames;
	int			noids;
	int			nrules;
	int			npatterns;
	ListCell   *lc;
	int			i = 0;

	value = slot_getattr(tslot, Anum_plans_relschemas, &isnull);
	if (isnull)
		return false;
	deconstruct_array(DatumGetArrayTypeP(value), TEXTOID, -1, false, 'i',
					  &schemas, NULL, &nschemas);
	value = slot_getattr(tslot, Anum_plans_relnames, &isnull);
	if (isnull)
		return false;
	deconstruct_array(DatumGetArrayTypeP(value), TEXTOID, -1, false, 'i',
					  &names, NULL, &nnames);
	value = slot_getattr(tslot, Anum_plans_reloids, &isnull);
	if (isnull)
		return false;
	deconstruct_array(DatumGetArrayTypeP(value), OIDOID, sizeof(Oid), true, 'i',
					  &oids, &oid_nulls, &noids);
	value = slot_getattr(tslot, Anum_plans_rules, &isnull);
	if (isnull)
		return false;
	deconstruct_array(DatumGetArrayTypeP(value), TEXTOID, -1, false, 'i',
					  &rules, NULL, &nrules);
	value = slot_getattr(tslot, Anum_plans_patterns, &isnull);
	if (isnull)
		return false;
	deconstruct_array(DatumGetArrayTypeP(value), TEXTOID, -1, false, 'i',
					  &patterns, &pattern_nulls, &npatterns);

	if (nschemas != list_length(key->slots) || nnames != nschemas ||
		noids != nschemas || nrules != nschemas || npatterns != nschemas)
		return false;

	foreach(lc, key->slots)
	{
		PmSlot	   *slot = (PmSlot *) lfirst(lc);
		const char *rule = TextDatumGetCString(rules[i]);
		const char *schema = TextDatumGetCString(schemas[i]);
		const char *relname = TextDatumGetCString(names[i]);

		if (strcmp(rule, "oid") == 0)
		{
			if (oid_nulls[i] || DatumGetObjectId(oids[i]) != slot->relid)
			{
				if (!oid_nulls[i] && *replaced_table == NULL &&
					strcmp(schema, slot->schema) == 0 &&
					strcmp(relname, slot->relname) == 0)
					*replaced_table = psprintf("%s.%s", schema, relname);
				return false;
			}
		}
		else if (strcmp(rule, "name") == 0)
		{
			if (strcmp(relname, slot->relname) != 0)
				return false;
		}
		else if (strcmp(rule, "schema.name") == 0)
		{
			if (strcmp(schema, slot->schema) != 0 ||
				strcmp(relname, slot->relname) != 0)
				return false;
		}
		else if (strcmp(rule, "regex") == 0)
		{
			char	   *full = psprintf("%s.%s", slot->schema, slot->relname);

			if (pattern_nulls[i] ||
				!pm_regex_matches(TextDatumGetCString(patterns[i]), full))
				return false;
		}
		else
			return false;
		i++;
	}
	return true;
}

/*
 * Find the hints stored for a query: the row with its key_oid, or else the
 * most specific matching row among those with its key_base.  When no row
 * applies but an enabled row failed only because a table it matches by OID
 * was recreated under its name, replaced_table names that table and
 * replaced_id is the id of that row.
 */
static char *
pm_lookup(const PmKey *key, int64 *row_id,
		  const char **replaced_table, int64 *replaced_id)
{
	Relation	heap;
	Relation	index;
	Snapshot	snapshot;
	ScanKeyData skeys[2];
	IndexScanDesc scan;
	TupleTableSlot *slot;
	char	   *hints = NULL;

	*row_id = 0;
	*replaced_table = NULL;
	*replaced_id = 0;

	heap = table_open(pm_use.plans_rel, AccessShareLock);
	index = index_open(pm_use.key_idx, AccessShareLock);
	snapshot = RegisterSnapshot(GetLatestSnapshot());
	slot = table_slot_create(heap, NULL);

	ScanKeyInit(&skeys[0], 1, BTEqualStrategyNumber, F_INT8EQ,
				Int64GetDatum(key->key_base));

	/* Stage 1: the row that matches every relation by OID */
	if (key->has_key_oid)
	{
		ScanKeyInit(&skeys[1], 2, BTEqualStrategyNumber, F_INT8EQ,
					Int64GetDatum(key->key_oid));
		scan = index_beginscan(heap, index, snapshot, 2, 0);
		index_rescan(scan, skeys, 2, NULL, 0);
		while (index_getnext_slot(scan, ForwardScanDirection, slot))
		{
			bool		isnull;
			Datum		value;

			value = slot_getattr(slot, Anum_plans_enabled, &isnull);
			if (isnull || !DatumGetBool(value))
				continue;
			value = slot_getattr(slot, Anum_plans_hints, &isnull);
			if (!isnull)
			{
				hints = TextDatumGetCString(value);
				value = slot_getattr(slot, Anum_plans_id, &isnull);
				*row_id = isnull ? 0 : DatumGetInt64(value);
				break;
			}
		}
		index_endscan(scan);
	}

	/* Stage 2: the most specific row matched by name or regular expression */
	if (hints == NULL)
	{
		int			best_oid = -1;
		int			best_name = -1;
		int			best_regex = -1;
		TimestampTz best_created = 0;

		scan = index_beginscan(heap, index, snapshot, 1, 0);
		index_rescan(scan, skeys, 1, NULL, 0);
		while (index_getnext_slot(scan, ForwardScanDirection, slot))
		{
			bool		isnull;
			Datum		value;
			int			n_oid;
			int			n_name;
			int			n_regex;
			TimestampTz created;
			bool		better;
			bool		by_oid_only;
			bool		matches;

			value = slot_getattr(slot, Anum_plans_enabled, &isnull);
			if (isnull || !DatumGetBool(value))
				continue;

			/*
			 * A row with a key_oid matches by OID only, and stage 1 missed it:
			 * it never applies here, but its slots tell whether a table of the
			 * query was recreated under the name the row holds.
			 */
			(void) slot_getattr(slot, Anum_plans_key_oid, &isnull);
			by_oid_only = !isnull;
			matches = pm_row_matches(slot, key, replaced_table);
			if (*replaced_table != NULL && *replaced_id == 0)
			{
				value = slot_getattr(slot, Anum_plans_id, &isnull);
				*replaced_id = isnull ? 0 : DatumGetInt64(value);
			}
			if (by_oid_only || !matches)
				continue;

			value = slot_getattr(slot, Anum_plans_n_oid, &isnull);
			n_oid = isnull ? 0 : DatumGetInt32(value);
			value = slot_getattr(slot, Anum_plans_n_name, &isnull);
			n_name = isnull ? 0 : DatumGetInt32(value);
			value = slot_getattr(slot, Anum_plans_n_regex, &isnull);
			n_regex = isnull ? 0 : DatumGetInt32(value);
			value = slot_getattr(slot, Anum_plans_created_at, &isnull);
			created = isnull ? 0 : DatumGetTimestampTz(value);

			if (n_oid != best_oid)
				better = n_oid > best_oid;
			else if (n_name != best_name)
				better = n_name > best_name;
			else if (n_regex != best_regex)
				better = n_regex > best_regex;
			else
				better = created > best_created;
			if (!better)
				continue;

			value = slot_getattr(slot, Anum_plans_hints, &isnull);
			if (isnull)
				continue;
			hints = TextDatumGetCString(value);
			value = slot_getattr(slot, Anum_plans_id, &isnull);
			*row_id = isnull ? 0 : DatumGetInt64(value);
			best_oid = n_oid;
			best_name = n_name;
			best_regex = n_regex;
			best_created = created;
		}
		index_endscan(scan);
	}

	if (hints != NULL)
	{
		*replaced_table = NULL;
		*replaced_id = 0;
	}

	ExecDropSingleTupleTableSlot(slot);
	UnregisterSnapshot(snapshot);
	index_close(index, AccessShareLock);
	table_close(heap, AccessShareLock);

	return hints;
}

/*
 * Is a row of this registration, the one with the same key_base and
 * identity, already stored with these hints?  The capture then leaves it as
 * it is, enabled or not, instead of replacing it at every execution of the
 * statement, which would leave a dead row in the store each time.
 */
static bool
pm_same_row_exists(const PmKey *key, const char *hints, int64 *row_id)
{
	Relation	heap;
	Relation	index;
	Snapshot	snapshot;
	ScanKeyData skey;
	IndexScanDesc scan;
	TupleTableSlot *slot;
	char	   *identity = pm_identity(key);
	bool		found = false;

	*row_id = 0;

	heap = table_open(pm_use.plans_rel, AccessShareLock);
	index = index_open(pm_use.key_idx, AccessShareLock);
	snapshot = RegisterSnapshot(GetLatestSnapshot());
	slot = table_slot_create(heap, NULL);

	ScanKeyInit(&skey, 1, BTEqualStrategyNumber, F_INT8EQ,
				Int64GetDatum(key->key_base));
	scan = index_beginscan(heap, index, snapshot, 1, 0);
	index_rescan(scan, &skey, 1, NULL, 0);
	while (index_getnext_slot(scan, ForwardScanDirection, slot))
	{
		bool		isnull;
		Datum		value;

		value = slot_getattr(slot, Anum_plans_identity, &isnull);
		if (isnull || strcmp(TextDatumGetCString(value), identity) != 0)
			continue;
		value = slot_getattr(slot, Anum_plans_hints, &isnull);
		if (isnull || strcmp(TextDatumGetCString(value), hints) != 0)
			continue;
		value = slot_getattr(slot, Anum_plans_id, &isnull);
		*row_id = isnull ? 0 : DatumGetInt64(value);
		found = true;
		break;
	}
	index_endscan(scan);

	ExecDropSingleTupleTableSlot(slot);
	UnregisterSnapshot(snapshot);
	index_close(index, AccessShareLock);
	table_close(heap, AccessShareLock);

	return found;
}

/*
 * Hint comments
 */

/*
 * Extract the hint comment from the head of a query string, with the same
 * acceptance rules as pg_hint_plan's get_hints_from_comment().
 */
static char *
pm_extract_hint_comment(const char *p)
{
	const char *head;
	const char *start;
	const char *end;

	if (p == NULL)
		return NULL;

	head = strstr(p, "/*+");
	if (head == NULL)
		return NULL;

	for (; p < head; p++)
	{
		if (!(*p >= '0' && *p <= '9') &&
			!(*p >= 'A' && *p <= 'Z') &&
			!(*p >= 'a' && *p <= 'z') &&
			!isspace((unsigned char) *p) &&
			*p != '_' && *p != ',' && *p != '(' && *p != ')')
			return NULL;
	}

	start = head + strlen("/*+");
	end = strstr(start, "*/");
	if (end == NULL)
		return NULL;

	while (start < end && isspace((unsigned char) *start))
		start++;
	while (end > start && isspace((unsigned char) end[-1]))
		end--;
	if (start == end)
		return NULL;

	return pnstrdup(start, end - start);
}

/*
 * Planning
 */

static PlannedStmt *
pm_call_next_planner(Query *parse, int cursorOptions, ParamListInfo boundParams)
{
	if (prev_planner_hook)
		return prev_planner_hook(parse, cursorOptions, boundParams);
	return standard_planner(parse, cursorOptions, boundParams);
}

static void
pm_hint_error_context(void *arg)
{
	/* Adds nothing to error messages; see pm_plan_with_hints() */
}

/*
 * Plan a query with stored hints.
 *
 * pg_hint_plan reads hints from the text of the query in three places:
 *   - its post_parse_analyze_hook stores them for its planner_hook, which
 *     applies them in the Postgres planner;
 *   - ORCA calls plan_hint_hook, which reads debug_query_string again;
 *   - inside PL/pgSQL its planner_hook takes the statement text from
 *     error_context_stack->arg.
 * All three see the stored hints as a comment prepended to the query text.
 */
static PlannedStmt *
pm_plan_with_hints(Query *parse, int cursorOptions, ParamListInfo boundParams,
				   const char *hints)
{
	const char *volatile saved_query_string = debug_query_string;
	char	   *hinted_query_string;
	ErrorContextCallback hint_context;
	PlannedStmt *result;

	hinted_query_string = psprintf("/*+ %s */ %s", hints,
								   saved_query_string ? saved_query_string : "");

	hint_context.callback = pm_hint_error_context;
	hint_context.arg = hinted_query_string;
	hint_context.previous = error_context_stack;

	PG_TRY();
	{
		debug_query_string = hinted_query_string;
		error_context_stack = &hint_context;

		if (hint_analyze_hook != NULL)
		{
			ParseState *pstate = make_parsestate(NULL);

			pstate->p_sourcetext = hinted_query_string;
			hint_analyze_hook(pstate, parse);
			free_parsestate(pstate);
		}

		result = pm_call_next_planner(parse, cursorOptions, boundParams);
	}
	PG_CATCH();
	{
		error_context_stack = hint_context.previous;
		debug_query_string = saved_query_string;
		PG_RE_THROW();
	}
	PG_END_TRY();

	error_context_stack = hint_context.previous;
	debug_query_string = saved_query_string;
	return result;
}

/*
 * The hint comment of the statement the client sent, when that statement is
 * the one being planned.  Hints written in the text of a query win over
 * whatever is stored for it.
 *
 * PostgreSQL 12 hands the planner no query text, so only the top-level
 * statement can be looked at: it is the one planned with no error context
 * set, while a statement inside a function is planned under the context of
 * SPI or of the function.
 */
static char *
pm_own_hint_comment(void)
{
	if (planner_nesting_level != 1 || error_context_stack != NULL)
		return NULL;

	return pm_extract_hint_comment(debug_query_string);
}

/*
 * Capture
 */

/*
 * Would the registration accept this text?  The capture stores only a text
 * that can be parsed again: exactly one statement, and one the planner
 * handles, not an EXPLAIN, which the DBA uses to try hints without storing
 * them, nor another utility statement such as EXECUTE or CREATE TABLE AS.
 * On refusal *reason says why.
 */
static bool
pm_capture_accepts(const char *text, const char **reason)
{
	MemoryContext oldcontext = CurrentMemoryContext;
	List	   *raw_statements = NIL;
	Node	   *stmt;

	*reason = NULL;
	PG_TRY();
	{
		raw_statements = pg_parse_query(text);
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		MemoryContextSwitchTo(oldcontext);
		edata = CopyErrorData();
		FlushErrorState();
		*reason = edata->message;
	}
	PG_END_TRY();
	if (*reason != NULL)
		return false;

	if (list_length(raw_statements) != 1)
	{
		*reason = psprintf("the string holds %d statements",
						   list_length(raw_statements));
		return false;
	}
	stmt = linitial_node(RawStmt, raw_statements)->stmt;
	if (IsA(stmt, SelectStmt) && ((SelectStmt *) stmt)->intoClause == NULL)
		return true;
	if (IsA(stmt, InsertStmt) || IsA(stmt, UpdateStmt) || IsA(stmt, DeleteStmt))
		return true;
	if (IsA(stmt, ExplainStmt))
	{
		*reason = "EXPLAIN is not stored, run the statement or call gg_planman.register_hints";
		return false;
	}
	*reason = "utility statements cannot have hints";
	return false;
}

/* The first temporary table of a query, or NULL */
static const char *
pm_temp_table(const PmKey *key)
{
	ListCell   *lc;

	foreach(lc, key->slots)
	{
		PmSlot	   *slot = (PmSlot *) lfirst(lc);

		if (slot->is_temp)
			return slot->relname;
	}
	return NULL;
}

static const char *
pm_key_text(const PmKey *key)
{
	if (key->has_key_oid)
		return psprintf("key_base=" INT64_FORMAT " key_oid=" INT64_FORMAT,
						key->key_base, key->key_oid);
	return psprintf("key_base=" INT64_FORMAT " key_oid=-", key->key_base);
}

static PlannedStmt *
pm_plan_query(Query *parse, int cursorOptions, ParamListInfo boundParams)
{
	PmKey		key;
	char	   *hints;
	char	   *own_hints;
	const char *replaced_table;
	int64		replaced_id;
	int64		row_id;

	own_hints = pm_own_hint_comment();

	/* Capture: store the hint comment of the statement the client sent */
	if (pm_write_mode && own_hints != NULL)
	{
		ArrayType  *by_name = NULL;
		const char *stored_text = debug_query_string;
		const char *refusal = "the statement text is not available";

		if (stored_text == NULL || !pm_capture_accepts(stored_text, &refusal))
		{
			ereport(WARNING,
					(errmsg("gg_planman: statement not captured: %s", refusal)));
			return pm_call_next_planner(parse, cursorOptions, boundParams);
		}

		pm_compute_key(parse, &key);

		/*
		 * A temporary table cannot be matched by OID across sessions, so the
		 * capture matches every temporary table of the statement by schema
		 * and name, as if by_name held the selector ~^pg_temp\., and keeps
		 * the selector in the row so that a regeneration gives the same rules.
		 */
		if (pm_temp_table(&key) != NULL)
		{
			Datum		elem = CStringGetTextDatum(PM_TEMP_SELECTOR);

			by_name = construct_array(&elem, 1, TEXTOID, -1, false, 'i');
			pm_assign_rules(&key, pm_parse_specs(by_name, false, "by_name"), NIL);
		}

		if (pm_same_row_exists(&key, own_hints, &row_id))
		{
			/* The row of this statement already holds these hints */
			if (pm_log_usage > 0)
				elog(pm_log_usage, "gg_planman: stored hints unchanged id=" INT64_FORMAT " %s",
					 row_id, pm_key_text(&key));
		}
		else
		{
			row_id = pm_store_row(&key, stored_text, own_hints, NULL, by_name, NULL, 0);

			if (pm_log_usage > 0)
				elog(pm_log_usage, "gg_planman: stored hints \"%s\" id=" INT64_FORMAT " %s",
					 own_hints, row_id, pm_key_text(&key));
		}

		/* The comment is still in the query text: pg_hint_plan applies it */
		return pm_call_next_planner(parse, cursorOptions, boundParams);
	}

	/*
	 * Hints written in the text of the query win over the hints stored for
	 * it: the next planner plans the query, and pg_hint_plan reads the
	 * comment as it does without gg_planman.
	 */
	if (own_hints != NULL)
	{
		if (pm_log_usage > 0)
		{
			pm_compute_key(parse, &key);
			if (pm_lookup(&key, &row_id, &replaced_table, &replaced_id) != NULL)
				elog(pm_log_usage,
					 "gg_planman: hints of the query text applied, stored hints not used id=" INT64_FORMAT " %s",
					 row_id, pm_key_text(&key));
		}
		return pm_call_next_planner(parse, cursorOptions, boundParams);
	}

	/* Lookup */
	pm_compute_key(parse, &key);
	hints = pm_lookup(&key, &row_id, &replaced_table, &replaced_id);

	if (hints == NULL)
	{
		if (replaced_table != NULL && pm_log_usage > 0)
			elog(pm_log_usage,
				 "gg_planman: stored hints not applied id=" INT64_FORMAT ": table %s was recreated, run gg_planman.check(regenerate => true) %s",
				 replaced_id, replaced_table, pm_key_text(&key));
		return pm_call_next_planner(parse, cursorOptions, boundParams);
	}

	if (pm_log_usage > 0)
		elog(pm_log_usage, "gg_planman: applying hints \"%s\" id=" INT64_FORMAT " %s",
			 hints, row_id, pm_key_text(&key));

	return pm_plan_with_hints(parse, cursorOptions, boundParams, hints);
}

static PlannedStmt *
pm_planner(Query *parse, int cursorOptions, ParamListInfo boundParams)
{
	PlannedStmt *result;

	if (!pm_enabled || parse->commandType == CMD_UTILITY || !pm_catalog_ready())
		return pm_call_next_planner(parse, cursorOptions, boundParams);

	planner_nesting_level++;
	PG_TRY();
	{
		result = pm_plan_query(parse, cursorOptions, boundParams);
	}
	PG_CATCH();
	{
		planner_nesting_level--;
		PG_RE_THROW();
	}
	PG_END_TRY();
	planner_nesting_level--;

	return result;
}

/*
 * SQL-callable functions
 */

static Query *
pm_analyze_query_text(const char *query_text, ArrayType *paramtypes_array)
{
	List	   *raw_statements;
	List	   *queries;
	Oid		   *paramtypes = NULL;
	int			nparams = 0;
	Query	   *query;

	if (paramtypes_array != NULL)
	{
		Datum	   *elems;
		bool	   *elem_nulls;
		int			i;

		deconstruct_array(paramtypes_array, REGTYPEOID, sizeof(Oid), true, 'i',
						  &elems, &elem_nulls, &nparams);
		paramtypes = palloc(sizeof(Oid) * (nparams + 1));
		for (i = 0; i < nparams; i++)
		{
			if (elem_nulls[i])
				ereport(ERROR,
						(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
						 errmsg("parameter types must not contain NULL")));
			paramtypes[i] = DatumGetObjectId(elems[i]);
		}
	}

	raw_statements = pg_parse_query(query_text);
	if (list_length(raw_statements) != 1)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("gg_planman expects exactly one statement, got %d",
						list_length(raw_statements))));

	if (IsA(linitial_node(RawStmt, raw_statements)->stmt, ExplainStmt))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("utility statements cannot have hints"),
				 errhint("The text is an EXPLAIN: register the statement inside it.")));

	queries = pg_analyze_and_rewrite(linitial_node(RawStmt, raw_statements),
									 query_text, paramtypes, nparams, NULL);
	if (list_length(queries) != 1)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("statement is rewritten into %d queries",
						list_length(queries))));

	query = linitial_node(Query, queries);
	if (query->commandType == CMD_UTILITY)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("utility statements cannot have hints")));

	return query;
}

static void
pm_require_catalog(void)
{
	if (!pm_catalog_ready())
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("gg_planman extension is not installed correctly")));
}

/* Only superusers change the plan store, as in pgpro_multiplan */
static void
pm_require_superuser(const char *action)
{
	if (!superuser())
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("must be superuser to %s", action)));
}

/* The keys and the slots of a query text registered with these arguments */
static void
pm_key_of_text(const char *query_text, ArrayType *paramtypes,
			   ArrayType *by_name, ArrayType *by_regex, PmKey *key)
{
	Query	   *query = pm_analyze_query_text(query_text, paramtypes);

	pm_compute_key(query, key);
	pm_assign_rules(key,
					pm_parse_specs(by_name, false, "by_name"),
					pm_parse_specs(by_regex, true, "by_regex"));
}

static Datum
pm_key_record(FunctionCallInfo fcinfo, const PmKey *key, int64 id, bool has_id)
{
	TupleDesc	tupdesc;
	Datum		values[4];
	bool		nulls[4] = {false, false, false, false};

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	values[0] = Int64GetDatum(id);
	nulls[0] = !has_id;
	values[1] = Int64GetDatum(key->key_base);
	values[2] = Int64GetDatum(key->key_oid);
	nulls[2] = !key->has_key_oid;
	values[3] = pm_slots_text(key);

	return HeapTupleGetDatum(heap_form_tuple(BlessTupleDesc(tupdesc), values, nulls));
}

/*
 * register_hints(query, hints, paramtypes, by_name, by_regex): store hints
 * for the query and return its keys and slots.
 */
Datum
pm_register_hints(PG_FUNCTION_ARGS)
{
	char	   *query_text;
	char	   *hints;
	ArrayType  *paramtypes;
	ArrayType  *by_name;
	ArrayType  *by_regex;
	PmKey		key;
	int64		id;

	if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("query and hints must not be NULL")));

	pm_require_superuser("store hints");
	pm_require_catalog();

	query_text = text_to_cstring(PG_GETARG_TEXT_PP(0));
	hints = text_to_cstring(PG_GETARG_TEXT_PP(1));
	paramtypes = PG_ARGISNULL(2) ? NULL : PG_GETARG_ARRAYTYPE_P(2);
	by_name = PG_ARGISNULL(3) ? NULL : PG_GETARG_ARRAYTYPE_P(3);
	by_regex = PG_ARGISNULL(4) ? NULL : PG_GETARG_ARRAYTYPE_P(4);

	pm_key_of_text(query_text, paramtypes, by_name, by_regex, &key);
	id = pm_store_row(&key, query_text, hints, paramtypes, by_name, by_regex, 0);

	PG_RETURN_DATUM(pm_key_record(fcinfo, &key, id, true));
}

/*
 * regenerate_row(row_id): register the row with this id again from its
 * stored text, hints, parameter types, by_name and by_regex, keeping the id.
 * The service check calls it for every row it finds invalid.
 */
Datum
pm_regenerate_row(PG_FUNCTION_ARGS)
{
	int64		row_id = PG_GETARG_INT64(0);
	Relation	heap;
	Relation	pkey;
	Snapshot	snapshot;
	ScanKeyData skey;
	IndexScanDesc scan;
	TupleTableSlot *slot;
	char	   *query_text = NULL;
	char	   *hints = NULL;
	ArrayType  *paramtypes = NULL;
	ArrayType  *by_name = NULL;
	ArrayType  *by_regex = NULL;
	PmKey		key;
	int64		id;

	pm_require_superuser("store hints");
	pm_require_catalog();

	heap = table_open(pm_use.plans_rel, AccessShareLock);
	pkey = index_open(pm_use.pkey_idx, AccessShareLock);
	snapshot = RegisterSnapshot(GetLatestSnapshot());
	slot = table_slot_create(heap, NULL);

	ScanKeyInit(&skey, 1, BTEqualStrategyNumber, F_INT8EQ,
				Int64GetDatum(row_id));
	scan = index_beginscan(heap, pkey, snapshot, 1, 0);
	index_rescan(scan, &skey, 1, NULL, 0);
	if (index_getnext_slot(scan, ForwardScanDirection, slot))
	{
		bool		isnull;
		Datum		value;

		value = slot_getattr(slot, Anum_plans_query, &isnull);
		if (!isnull)
			query_text = TextDatumGetCString(value);
		value = slot_getattr(slot, Anum_plans_hints, &isnull);
		if (!isnull)
			hints = TextDatumGetCString(value);
		value = slot_getattr(slot, Anum_plans_paramtypes, &isnull);
		if (!isnull)
			paramtypes = DatumGetArrayTypePCopy(value);
		value = slot_getattr(slot, Anum_plans_by_name, &isnull);
		if (!isnull)
			by_name = DatumGetArrayTypePCopy(value);
		value = slot_getattr(slot, Anum_plans_by_regex, &isnull);
		if (!isnull)
			by_regex = DatumGetArrayTypePCopy(value);
	}
	index_endscan(scan);

	ExecDropSingleTupleTableSlot(slot);
	UnregisterSnapshot(snapshot);
	index_close(pkey, AccessShareLock);
	table_close(heap, AccessShareLock);

	if (query_text == NULL || hints == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("no stored row with id " INT64_FORMAT, row_id)));

	pm_key_of_text(query_text, paramtypes, by_name, by_regex, &key);
	id = pm_store_row(&key, query_text, hints, paramtypes, by_name, by_regex, row_id);

	PG_RETURN_DATUM(pm_key_record(fcinfo, &key, id, true));
}

/* query_key(query, paramtypes, by_name, by_regex): the keys of a query text */
Datum
pm_query_key(PG_FUNCTION_ARGS)
{
	PmKey		key;

	if (PG_ARGISNULL(0))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("query must not be NULL")));

	pm_key_of_text(text_to_cstring(PG_GETARG_TEXT_PP(0)),
				   PG_ARGISNULL(1) ? NULL : PG_GETARG_ARRAYTYPE_P(1),
				   PG_ARGISNULL(2) ? NULL : PG_GETARG_ARRAYTYPE_P(2),
				   PG_ARGISNULL(3) ? NULL : PG_GETARG_ARRAYTYPE_P(3),
				   &key);

	PG_RETURN_DATUM(pm_key_record(fcinfo, &key, 0, false));
}

/*
 * plan_info(query, paramtypes): what the optimizer puts into the plan of a
 * query that matters for storing hints.  Stored rows are not applied.
 */
Datum
pm_plan_info(PG_FUNCTION_ARGS)
{
	Query	   *query;
	PlannedStmt *stmt;
	TupleDesc	tupdesc;
	Datum		values[4];
	bool		nulls[4] = {false, false, false, false};
	List	   *segments = NIL;
	bool		direct = false;
	Datum	   *elems;
	ListCell   *lc;
	int			nelems = 0;
	int			i;

	if (PG_ARGISNULL(0))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("query must not be NULL")));

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	query = pm_analyze_query_text(text_to_cstring(PG_GETARG_TEXT_PP(0)),
								  PG_ARGISNULL(1) ? NULL : PG_GETARG_ARRAYTYPE_P(1));
	stmt = pm_call_next_planner(query, 0, NULL);

	for (i = 0; i < stmt->numSlices; i++)
	{
		DirectDispatchInfo *dd = &stmt->slices[i].directDispatch;

		if (dd->isDirectDispatch)
		{
			direct = true;
			segments = list_concat_unique_int(segments, dd->contentIds);
		}
	}

	elems = palloc(sizeof(Datum) * (list_length(segments) + 1));
	foreach(lc, segments)
		elems[nelems++] = Int32GetDatum(lfirst_int(lc));

	values[0] = CStringGetTextDatum(stmt->planGen == PLANGEN_OPTIMIZER ?
									"GPORCA" : "Postgres planner");
	values[1] = Int32GetDatum(stmt->numSlices);
	values[2] = BoolGetDatum(direct);
	values[3] = PointerGetDatum(construct_array(elems, nelems, INT4OID,
												sizeof(int32), true, 'i'));

	PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(BlessTupleDesc(tupdesc),
													  values, nulls)));
}

void
_PG_init(void)
{
	DefineCustomBoolVariable("gg_planman.enabled",
							 "Apply stored hints.",
							 NULL,
							 &pm_enabled,
							 true,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("gg_planman.write_mode",
							 "Store the hint comment of every planned top-level query.",
							 NULL,
							 &pm_write_mode,
							 false,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomEnumVariable("gg_planman.log_usage",
							 "Log stored and applied hints with the specified level.",
							 NULL,
							 &pm_log_usage,
							 0,
							 log_usage_options,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

	if (process_shared_preload_libraries_in_progress &&
		(planner_hook == NULL || post_parse_analyze_hook == NULL))
		ereport(WARNING,
				(errmsg("gg_planman is loaded before pg_hint_plan"),
				 errhint("List pg_hint_plan before gg_planman in shared_preload_libraries.")));

	hint_analyze_hook = post_parse_analyze_hook;

	prev_planner_hook = planner_hook;
	planner_hook = pm_planner;
}
