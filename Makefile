TESTS=test syntax json_schemas

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove -vrl --timer
ifeq ($(GITHUB_ACTIONS),true)
	EXTRA_ARGS = --merge --formatter TAP::Formatter::JUnit::PrintTxtStdout
else
	EXTRA_ARGS =
endif
PROVE=p () { $M; echo '$P' $(EXTRA_ARGS) "$$@"; $P $(EXTRA_ARGS) "$$@"; }; p

test_all: $(TESTS)

syntax_diff:
	@$(PROVE) --norc $$(ls t/*.t | grep -v syntax_all)

syntax:
	@$(PROVE) --norc t/*.t

accounts:
	@$(PROVE) t/BOM/RPC/10_Accounts t/BOM/999_redis_keys.t

misc:
	@$(PROVE) t/BOM/RPC/25_Misc t/BOM/RPC/50_Misc t/BOM/999_redis_keys.t

mt5:
	@$(PROVE) t/BOM/RPC/50_MT5 t/BOM/999_redis_keys.t

transaction:
	@$(PROVE) t/BOM/RPC/75_Transaction t/BOM/RPC/15_Cashier t/BOM/999_redis_keys.t

others:
	@$(PROVE) $$(find t/BOM/RPC -maxdepth 1 | grep -vE "(RPC|10_Accounts|75_Transaction|15_Cashier|Misc|50_MT5)$$" | sort)

test: t/BOM/RPC t/BOM/999_redis_keys.t

test1:
	@$(PROVE) t/BOM/RPC/[0-4]* t/BOM/999_redis_keys.t

test2:
	@$(PROVE) t/BOM/RPC/[5-9]* t/BOM/999_redis_keys.t

pod_test:
	@$(PROVE) --norc t/*pod*.t

json_schemas:
	@$(PROVE) t/schema_suite/*.t

tidy:
	find . -name '*.p?.bak' -delete
	find bin lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidier -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

cover:
	cover -delete
	sed -i '1667,1668d' /home/git/binary-com/perl/lib/5.26.2/B/Deparse.pm
	PERL5OPT='-MBOM::Test' HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc --ignore-exit -It/lib t/BOM/RPC/ t/unit/
	cover -report coveralls

unit:
	@$(PROVE) t/unit/
