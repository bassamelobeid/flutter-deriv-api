M=[ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
export PERL5OPT=-MTest::FailWarnings=-allow_deps,1
P=/etc/rmg/bin/prove --timer -rl -I lib
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test:
	@$(PROVE) $$(ls -1d t/BOM)

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
