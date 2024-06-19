TESTS=test syntax

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove --merge -v --timer -rl -It/lib
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

tidy:
	find . -name '*.p?.bak' -delete
	find . -not -path "./.git*" -not -path "./srp*" -not -path "./.vscode*" -name '*.p[lm]' -o -name '*.t' | xargs perltidier -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

test:
	@$(PROVE) t/BOM

cover:
	cover -delete
	PERL5OPT=-MBOM::Test HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc   t/BOM/
	cover -report coveralls

pod_test:
	@$(PROVE) --norc t/*pod*.t

