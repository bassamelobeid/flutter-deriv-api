TESTS=test unit syntax

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=/etc/rmg/bin/prove -rlv --timer
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test_all: $(TESTS)

test:
	@$(PROVE) t/BOM

syntax_diff:
	@$(PROVE) --norc $$(ls t/*.t | grep -v syntax_all)

syntax:
	@$(PROVE) --norc t/*.t

tidy:
	find . -name '*.p?.bak' -delete
	find . -not -path "./.git*" -name '*.p[lm]' -o -name '*.t' | xargs perltidier -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

pod_test:
	@$(PROVE) --norc t/*pod*.t

cover:
	# disable specific warning for Deparse.pm, it flood during the tests.
	# code coverage test should exclude those memeory or benchmark performance tests.
	cover -delete
	sed -i '/unexpected OP/,/OP_CUSTOM/d' /home/git/binary-com/perl/lib/5.26.2/B/Deparse.pm
	HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer --ignore-exit --norc -rl -MBOM::Test  $$(find t/unit t/BOM -name "*.t" | grep -v 'memory')
	cover -report coveralls

unit:
	@$(PROVE) t/unit
