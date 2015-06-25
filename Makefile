TESTS=unit_test_market \
      unit_test_marketdata \
      unit_test_product_contract \
      unit_test_product_all \

M=rm -f /tmp/l4p.log && [ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=prove --timer -I$D/lib -I$D -I$D/t  -I/home/git/regentmarkets/bom-postgres/lib
L=|| { [ -t 1 -a "$$TRAVIS" != true ] && echo '\033[01;31msee also /tmp/l4p.log\033[00m' || cat /tmp/l4p.log; false; }
PROVE=p () { $M; echo '$P' "$$@"; BOM_LOG4PERLCONFIG=$D/t/config/log4perl.conf $P "$$@" $L; }; p

default:
	@echo "You must specify target. The following targets available:"
	@echo "  i18n         - extract translatable strings from the code"
	@echo "  test         - Run lib tests"
	@echo "  tidy         - Run perltidy"

critique:
	prove -l t/BOM/002_autosyntax.t

test: $(TESTS)

test_all: test unit_test_myaffiliates_extended

unit_test_market:
	@$(PROVE) -r t/BOM/Market/

unit_test_marketdata:
	@$(PROVE) -r t/BOM/MarketData/

unit_test_product_contract:
	@$(PROVE) -r t/BOM/Product/Contract/ -r t/BOM/Product/ContractFactory/

unit_test_product_all:
	@$(PROVE) -r $$(ls -1d t/BOM/Product/* | grep -v -e /Contract)

tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

compile:
	prove -v -l t/BOM/002_autosyntax.t

syntax_lib:
	SYNTAX_CHUNK_NAME=lib prove -I./lib -I/home/git/regentmarkets/bom-postgres/lib t/BOM/002_autosyntax.t
	prove -l t/BOM/003_yaml_correctness.t

syntax_cgi:
	SYNTAX_CHUNK_NAME=cgi prove -I./lib -I/home/git/regentmarkets/bom-postgres/lib t/BOM/002_autosyntax.t

