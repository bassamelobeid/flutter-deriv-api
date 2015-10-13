TESTS=unit_test_market

M=rm -f /tmp/l4p.log && [ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=prove --timer -I$D/lib -I$D -I$D/t  -I/home/git/regentmarkets/bom-postgres/lib
L=|| { [ -t 1 -a "$$TRAVIS" != true ] && echo '\033[01;31msee also /tmp/l4p.log\033[00m' || cat /tmp/l4p.log; false; }
PROVE=p () { $M; echo '$P' "$$@"; BOM_LOG4PERLCONFIG=/home/git/regentmarkets/bom-test/data/config/log4perl.conf $P "$$@" $L; }; p

test: $(TESTS)

unit_test_market:
	@$(PROVE) -r t/BOM/

tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

syntax_lib:
	SYNTAX_CHUNK_NAME=lib prove -I./lib -I/home/git/regentmarkets/bom-postgres/lib t/BOM/002_autosyntax.t

