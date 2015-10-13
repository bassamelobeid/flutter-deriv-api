TESTS=unit_test_product_contract \
      unit_test_product_all \

M=rm -f /tmp/l4p.log && [ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=prove --timer -I$D/lib -I$D -I$D/t  -I/home/git/regentmarkets/bom-postgres/lib
L=|| { [ -t 1 -a "$$TRAVIS" != true ] && echo '\033[01;31msee also /tmp/l4p.log\033[00m' || cat /tmp/l4p.log; false; }
PROVE=p () { $M; echo '$P' "$$@"; BOM_LOG4PERLCONFIG=/home/git/regentmarkets/bom-test/data/config/log4perl.conf $P "$$@" $L; }; p


test: $(TESTS)

unit_test_product_contract:
	@$(PROVE) -r t/BOM/Product/Contract/ -r t/BOM/Product/ContractFactory/

unit_test_product_all:
	@$(PROVE) -r $$(ls -1d t/BOM/* | grep -v -e Product/Contract)

tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
