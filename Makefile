TESTS=test unit syntax

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
export SKIP_EMAIL=1
P=/etc/rmg/bin/prove -vrl --timer -I/home/git/regentmarkets/perl-WebService-Async-DevExperts/lib -I/home/git/regentmarkets/perl-WebService-Async-DevExperts/local/lib/perl5
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
	@$(PROVE) --norc t/*pod*.t

tidy:
	find . -name '*.p?.bak' -delete
	find . -not -path "./.git*" -name '*.p[lm]' -o -name '*.t' | xargs perltidier -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

syntax_diff:
	@$(PROVE) --norc $$(ls t/*.t | grep -v syntax_all)

syntax:
	@$(PROVE) --norc t/*.t

cover:
	cover -delete
	# disable specific warning for Deparse.pm, it flood during the tests.
	sed -i '/unexpected OP/,/OP_CUSTOM/d' /home/git/binary-com/perl/lib/5.26.2/B/Deparse.pm
	PERL5OPT=-MBOM::Test HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc --ignore-exit -I/home/git/regentmarkets/perl-WebService-Async-DevExperts/lib -I/home/git/regentmarkets/perl-WebService-Async-DevExperts/local/lib/perl5 t/BOM/ t/unit/
	# cover -report coveralls
unit:
	@$(PROVE) t/unit/

create_jwt_keys:
	perl bin/create_jwt_keys.pl
