TESTS=unit_test_marketdataautoupdater

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=/etc/rmg/bin/prove -v --timer -I$D/lib -I$D -I$D/t  -I/home/git/regentmarkets/bom-postgres/lib
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p
test: $(TESTS)

unit_test_marketdataautoupdater:
	@$(PROVE) -r t/BOM/

tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
