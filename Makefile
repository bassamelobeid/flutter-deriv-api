TESTS=test syntax

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=/etc/rmg/bin/prove -vlr --timer -I$D/t  -I/home/git/regentmarkets/bom-postgres/lib
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p
test_all: $(TESTS)

test:
	@$(PROVE) t/BOM

syntax:
	@$(PROVE) t/*.t

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

cover:
	cover -delete
	HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc -MBOM::Test  t/BOM/MarketDataAutoUpdater
	cover -report coveralls
