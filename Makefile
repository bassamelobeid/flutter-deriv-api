M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=/etc/rmg/bin/prove -v --timer -I$D/lib -I$D -I$D/t
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test:
	@$(PROVE) -r t/
tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

doc:
	pod2markdown lib/BOM/Transaction.pm > README.md

cover:
	cover -delete
	HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc -MBOM::Test t/BOM/
	cover -report coveralls
