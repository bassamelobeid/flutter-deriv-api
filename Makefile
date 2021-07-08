TESTS=test syntax json_schemas

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove -vrl --timer
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test_all: $(TESTS)

syntax:
	@$(PROVE) --norc t/*.t

test:
	@$(PROVE) t/BOM/ t/999_redis_keys.t

pod_test:
	@$(PROVE) --norc t/*pod*.t

json_schemas:
	@$(PROVE) t/schema_suite/*.t

tidy:
	find . -name '*.p?.bak' -delete
	find bin lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

cover:
	cover -delete
	sed -i '1667,1668d' /home/git/binary-com/perl/lib/5.26.2/B/Deparse.pm
	PERL5OPT='-MBOM::Test' HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc --ignore-exit -It/lib t/BOM/RPC/ t/unit/
	cover -report coveralls
	
unit:
	@$(PROVE) t/unit/
