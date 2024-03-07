TESTS=test unit syntax 

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove -vrl --timer 
ifeq ($(GITHUB_ACTIONS),true)
	EXTRA_ARGS = --merge --formatter TAP::Formatter::JUnit::PrintTxtStdout
else
	EXTRA_ARGS =
endif
PROVE=p () { $M; echo '$P' $(EXTRA_ARGS) "$$@"; $P $(EXTRA_ARGS) "$$@"; }; p

test_all: $(TESTS)

test:
	@$(PROVE) t/BOM

pod_test:
	@$(PROVE) t/*pod*.t


syntax_diff:
	@$(PROVE) --norc $$(ls t/*.t | grep -v syntax_all)

syntax:
	@$(PROVE) --norc t/*.t

tidy:
	find . -name '*.p?.bak' -delete
	find bin lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidier -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

doc:
	pod2markdown lib/BOM/OAuth.pm > README.md

cover:
	cover -delete
	PERL5OPT=-MBOM::Test HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc   t/BOM/ t/unit/
	cover -report coveralls
	
unit:
	@$(PROVE) t/unit
