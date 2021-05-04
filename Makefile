M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
export SKIP_EMAIL=1
I=-I$D/lib -I$D -I/home/git/regentmarkets/cpan/local/lib
P=/etc/rmg/bin/prove -v --timer $I
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test:
	@$(PROVE) -r t/BOM

tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

syntax:
	@$(PROVE) --norc t/*.t

pod_test:
	@$(PROVE) t/*pod*.t

cover:
	cover -delete
	HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc t/BOM
	cover -report coveralls
