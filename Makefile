CORETESTS=unit_test_product_contract \
      unit_test_product_all \

ALLTESTS=test syntax 

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=/etc/rmg/bin/prove -v --timer -I$D/lib -I$D -I$D/t
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test_all: $(ALLTESTS)
test: $(CORETESTS)

syntax:
	@$(PROVE) t/*.t

unit_test_initial:
	@$(PROVE) t/01_check_file_hash.t

unit_test_product_contract:
	@$(PROVE) -r t/BOM/Product/Contract/

unit_test_product_contract_extended:
	@$(PROVE) -r t/BOM/Product/ContractFactory/ -r t/BOM/Product/ContractExtended/

unit_test_product_all:
	@$(PROVE) -r $$(ls -1d t/BOM/Persistence/* t/BOM/*.t t/BOM/Product/* | grep -v -e Product/Contract -e Product/ContractExtended -e Product/Validation -e Product/Pricing)

unit_test_validation:
	@$(PROVE) -r t/BOM/Product/Validation

unit_test_pricing:
	@$(PROVE) -r $$(ls -1d t/BOM/Product/Pricing*)

unit_test_intraday:
	@$(PROVE) -r t/BOM/Product/Pricing/Engine/IntradayHistorical

pod_test:
	@$(PROVE) t/*pod*.t

tidy:
	find . -name '*.p?.bak' -delete
	find . -not -path "./.git*" -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

doc:
	pod2markdown lib/BOM/Product/Contract.pm > README.md

cover:
	cover -delete
	PERL5OPT=-MBOM::Test HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer --norc -It/lib -rl $$(find t/BOM -name "*.t" | grep -vE 'memtest|benchmark|ContractFinder')
	cover -report coveralls

