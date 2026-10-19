#ifndef GG_PLANMAN_H
#define GG_PLANMAN_H

#include "postgres.h"

#define PM_EXTENSION_NAME		"gg_planman"
#define PM_SCHEMA_NAME			"gg_planman"
#define PM_PLANS_TABLE			"plans"
#define PM_PLANS_KEY_INDEX		"plans_key_idx"
#define PM_PLANS_ID_SEQ			"plans_id_seq"
#define PM_PLANS_PKEY_INDEX		"plans_pkey"

/* Attributes of gg_planman.plans, see init.sql */
enum
{
	Anum_plans_id = 1,
	Anum_plans_key_base,
	Anum_plans_key_oid,
	Anum_plans_enabled,
	Anum_plans_hints,
	Anum_plans_query,
	Anum_plans_paramtypes,
	Anum_plans_relschemas,
	Anum_plans_relnames,
	Anum_plans_reloids,
	Anum_plans_rules,
	Anum_plans_patterns,
	Anum_plans_n_oid,
	Anum_plans_n_name,
	Anum_plans_n_regex,
	Anum_plans_identity,
	Anum_plans_by_name,
	Anum_plans_by_regex,
	Anum_plans_funcoids,
	Anum_plans_created_at,
	Natts_plans = Anum_plans_created_at
};

#endif
