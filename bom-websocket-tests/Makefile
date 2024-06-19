M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove -lvr --timer

ifeq ($(GITHUB_ACTIONS),true)
	EXTRA_ARGS = --merge --formatter TAP::Formatter::JUnit::PrintTxtStdout
else
	EXTRA_ARGS =
endif
PROVE=p () { $M; echo '$P' $(EXTRA_ARGS) "$$@"; $P $(EXTRA_ARGS) "$$@"; }; p


tidy:
	find . -name '*.p?.bak' -delete
	find v3 t -name '*.p[lm]' -o -name '*.t' | xargs perltidier -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

test:
	@$(PROVE) t
