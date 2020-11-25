M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove --timer -rvl -I lib
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test:
	@$(PROVE) t/

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

pod_test:
	@$(PROVE) t/*pod*.t

cover:
	cover -delete
	HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer --norc  -MBOM::Test -rl  t/BOM/Pricing/
	cover -report coveralls
