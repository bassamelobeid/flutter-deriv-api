TESTS=test unit syntax

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove -lrv --timer
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test_all: $(TESTS)

tidy:
	find . -name '*.p?.bak' -delete
	find . -not -path "./.git*" -not -path "./srp*" -name '*.p[lm]' -o -name '*.t' | xargs perltidier -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

test:
	@$(PROVE) -r t/BOM/

syntax_diff:
	@$(PROVE) --norc $$(ls t/*.t | grep -v syntax_all)

syntax:
	@$(PROVE) --norc t/*.t

pod_test:
	@$(PROVE) --norc t/*pod*.t

cover:
	cover -delete
	sed -i '1667,1668d' /home/git/binary-com/perl/lib/5.26.2/B/Deparse.pm
	PERL5OPT=-MBOM::Test HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer --norc --ignore-exit -rl t/BOM/ t/unit/
	cover -report coveralls

unit:
	@$(PROVE) -r t/unit/
