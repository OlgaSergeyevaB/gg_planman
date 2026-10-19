# gg_planman/Makefile

MODULE_big = gg_planman
OBJS = gg_planman.o $(WIN32RES)

PGFILEDESC = "gg_planman - plan management for Greengage: stored hints"

EXTENSION = gg_planman
EXTVERSION = 0.1
DATA_built = gg_planman--$(EXTVERSION).sql

EXTRA_CLEAN = gg_planman--$(EXTVERSION).sql
#REGRESS =

ifdef USE_PGXS
ifndef PG_CONFIG
PG_CONFIG = pg_config
endif
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = gpcontrib/gg_planman
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif

$(EXTENSION)--$(EXTVERSION).sql: init.sql
	cat $^ > $@
