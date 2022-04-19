TESTS=test unit syntax 

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove --timer -rvl
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test_all: $(TESTS)

test:
	@$(PROVE) t/plack

syntax_diff:
	@$(PROVE) --norc t/00_syntax_diff.t t/01_check_bom_dependency.t t/006_pod_coverage.t

syntax:
	@$(PROVE) --norc t/*.t

tidy:
	find . -name '*.p?.bak' -delete
	find scripts lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

doc:
	pod2markdown lib/BOM/API/Payment.pm > README.md

cover:
	cover -delete
	PERL5OPT=-MBOM::Test HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc   t/plack t/unit
	cover -report coveralls
	
unit:
	@$(PROVE) t/unit
