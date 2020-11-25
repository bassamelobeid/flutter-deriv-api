M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=PERL5OPT=-MTest::Warnings /etc/rmg/bin/prove --timer -rvl
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p


test:
	@$(PROVE) t/

syntax:
	@$(PROVE) t/*.t

tidy:
	find . -name '*.p?.bak' -delete
	find scripts lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

doc:
	pod2markdown lib/BOM/API/Payment.pm > README.md

cover:
	cover -delete
	HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc -MBOM::Test  t/plack
	cover -report coveralls
