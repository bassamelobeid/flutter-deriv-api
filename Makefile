TESTS=unit_test_platform_client \
      unit_test_platform_all \
      unit_test_system

M=rm -f /tmp/l4p.log && [ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
I=-I$D/lib -I$D -I/home/git/regentmarkets/bom/t -I/home/git/regentmarkets/bom-postgres/lib -I/home/git/regentmarkets/bom/lib
P=prove --timer $I
L=|| { [ -t 1 -a "$$TRAVIS" != true ] && echo '\033[01;31msee also /tmp/l4p.log\033[00m' || cat /tmp/l4p.log; false; }
PROVE=p () { $M; echo '$P' "$$@"; BOM_LOG4PERLCONFIG=$D/t/config/log4perl.conf $P "$$@" $L; }; p

default:
	@echo "You must specify target. The following targets available:"
	@echo "  i18n         - extract translatable strings from the code"
	@echo "  test         - Run lib tests"
	@echo "  tidy         - Run perltidy"

critique:
	prove -l t/002_autosyntax.t

test: $(TESTS)

test_all: test unit_test_myaffiliates_extended

unit_test_platform_client:
	@$(PROVE) -r t/BOM/Platform/Client/

unit_test_platform_all:
	@$(PROVE) -r $$(ls -1d t/BOM/Platform/* | grep -v -e /Client -e /MyAffiliates)

unit_test_system:
	@$(PROVE) -r t/BOM/System/

unit_test_bdd:
	@$M
	(cd /home/git/regentmarkets/bdd && \
         BOM_LOG4PERLCONFIG=$D/t/config/log4perl.conf \
         PERL5OPT="$I -I/home/git/regentmarkets/bdd/lib -MTest::MockTime::HiRes" \
         pherkin -l)

unit_test_myaffiliates_extended:
	@export EXTENDED_TESTING=1; unset SKIP_MYAFFILIATES; $(PROVE) -r t/BOM/Platform/MyAffiliates/

tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

compile:
	prove -v -l t/002_autosyntax.t

syntax_lib:
	SYNTAX_CHUNK_NAME=lib prove -I./lib -I/home/git/regentmarkets/bom-postgres/lib t/002_autosyntax.t

syntax_cgi:
	SYNTAX_CHUNK_NAME=cgi prove -I./lib -I/home/git/regentmarkets/bom-postgres/lib t/002_autosyntax.t

