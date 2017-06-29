TESTS=unit_test_market

M=[ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=/etc/rmg/bin/prove --timer -I$D/lib -I$D -I$D/t  -I/home/git/regentmarkets/bom-postgres/lib
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p
export PERL5OPT=-MTest::Warnings
test: $(TESTS)

unit_test_market:
	@$(PROVE) -j2 -vr t/BOM/

tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
