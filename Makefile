TESTS=test syntax 

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
export SKIP_EMAIL=1
P=/etc/rmg/bin/prove -vrl --timer 
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test_all: $(TESTS)

test:
	@$(PROVE) t/BOM

unit_test_platform_client:
	@$(PROVE) t/BOM/Platform/Client/

unit_test_platform_all:
	@$(PROVE) $$(ls -1d t/BOM/Platform/* | grep -v -e /Client)

unit_test_system:
	@$(PROVE) t/BOM/System/

leaktest:
	@$(PROVE) t/BOM/leaks

pod_test:
	@$(PROVE) t/*pod*.t

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

syntax:
	@$(PROVE) t/*.t

cover:
	cover -delete
	PERL5OPT=-MBOM::Test HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc  -MBOM::Test::Script::ExperianMock t/BOM/
	cover -report coveralls
