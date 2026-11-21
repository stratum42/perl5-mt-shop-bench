PERL5_MT_ROOT       ?= $(abspath $(CURDIR)/../perl5-mt)
SHOP_ROOT           ?= $(abspath $(CURDIR)/../perl5-mt-shop)
MOJOLICIOUS_MT_ROOT ?= $(abspath $(CURDIR)/../mojolicious-mt)
PERL                ?= $(shell command -v perl5-mt 2>/dev/null || echo $(PERL5_MT_ROOT)/perl)
PERL_LIB            ?= $(PERL5_MT_ROOT)/lib
XS_DIR              := $(SHOP_ROOT)/xs/Shop-SSH-Crypto

MOJO_FLAGS       := $(if $(wildcard $(MOJOLICIOUS_MT_ROOT)/lib),-I$(MOJOLICIOUS_MT_ROOT)/lib -I$(MOJOLICIOUS_MT_ROOT)/xs/blib/lib -I$(MOJOLICIOUS_MT_ROOT)/xs/blib/arch,)
MOJO_KEYDB_FLAGS := $(if $(wildcard $(MOJOLICIOUS_MT_ROOT)/xs-keydb/blib/lib),-I$(MOJOLICIOUS_MT_ROOT)/xs-keydb/blib/lib -I$(MOJOLICIOUS_MT_ROOT)/xs-keydb/blib/arch,)
PERL_FLAGS       := -I$(PERL_LIB) -I$(SHOP_ROOT)/lib -I$(XS_DIR)/blib/lib -I$(XS_DIR)/blib/arch $(MOJO_FLAGS) $(MOJO_KEYDB_FLAGS)

BENCH_ARGS ?=

export PERL5_MT_ROOT
export SHOP_ROOT
export MOJOLICIOUS_MT_ROOT

.PHONY: all smoke ssh egress micro http db fault

all:
	@mkdir -p $(CURDIR)/results
	$(PERL) $(PERL_FLAGS) $(CURDIR)/bench/run_all.pl $(BENCH_ARGS)

smoke:
	@mkdir -p $(CURDIR)/results
	$(PERL) $(PERL_FLAGS) $(CURDIR)/bench/run_all.pl --smoke $(BENCH_ARGS)

ssh:
	@mkdir -p $(CURDIR)/results
	$(PERL) $(PERL_FLAGS) $(CURDIR)/bench/01_ssh_concurrency_rss.pl --json $(CURDIR)/results/01_ssh_concurrency_rss.json $(BENCH_ARGS)

egress:
	@mkdir -p $(CURDIR)/results
	$(PERL) $(PERL_FLAGS) $(CURDIR)/bench/02_egress_matrix.pl --json $(CURDIR)/results/02_egress_matrix.json $(BENCH_ARGS)

micro:
	@mkdir -p $(CURDIR)/results
	$(PERL) $(PERL_FLAGS) $(CURDIR)/bench/03_crypto_cas_decimal.pl --json $(CURDIR)/results/03_crypto_cas_decimal.json $(BENCH_ARGS)

http:
	@mkdir -p $(CURDIR)/results
	$(PERL) $(PERL_FLAGS) $(CURDIR)/bench/04_http_ops_wrk.pl --json $(CURDIR)/results/04_http_ops_wrk.json $(BENCH_ARGS)

db:
	@mkdir -p $(CURDIR)/results
	$(PERL) $(PERL_FLAGS) $(CURDIR)/bench/05_databases_compare.pl --json $(CURDIR)/results/05_databases_compare.json $(BENCH_ARGS)

fault:
	@mkdir -p $(CURDIR)/results
	$(PERL) $(PERL_FLAGS) $(CURDIR)/bench/06_fault_tolerance.pl --json $(CURDIR)/results/06_fault_tolerance.json $(BENCH_ARGS)
