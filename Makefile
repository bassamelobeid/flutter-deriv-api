CORETESTS=unit_test_product_contract \
      unit_test_product_contract_settlement \
      unit_test_product_base \
      unit_test_product_model \
      unit_test_volatility \
      unit_test_offerings \

TESTS=test syntax

PRODUCTALL=unit_test_validation \
      unit_test_product_contract \
      unit_test_product_contract_settlement \
      unit_test_product_contract_extended \
      unit_test_product_base \
      unit_test_product_model \
      unit_test_volatility \
      unit_test_offerings \
      unit_test_product_contract_finder \

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=/etc/rmg/bin/prove -v --timer -I$D/lib -I$D -I$D/t
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test_all: $(TESTS)

unit_test_syntax:
	@$(PROVE) --norc t/*.t

test: $(CORETESTS)

syntax:
	@$(PROVE) --norc t/*.t

unit_test_product_contract:
	@$(PROVE) -r t/BOM/Product/Contract/ -r t/BOM/Product/ContractFinder/

unit_test_product_contract_settlement:
	@$(PROVE) -r t/BOM/Product/Contract/Settlement/

unit_test_product_contract_extended:
	@$(PROVE) -r t/BOM/Product/ContractFactory/ -r t/BOM/Product/ContractExtended/

unit_test_product_contract_finder:
	@$(PROVE) -r t/BOM/Product/ContractFinder/

unit_test_validation:
	@$(PROVE) -r t/BOM/Product/Validation/

unit_test_volatility:
	@$(PROVE) -r t/BOM/Product/Volatility/

unit_test_product_model:
	@$(PROVE) -r t/BOM/Product/Model/

unit_test_pricing:
	@$(PROVE) -r t/BOM/Product/Pricing/

unit_test_intraday:
	@$(PROVE) -r t/BOM/Product/Pricing/Engine/IntradayHistorical

unit_test_offerings:
	@$(PROVE) -r t/BOM/Product/Offerings/

unit_test_product_base:
	@$(PROVE) t/BOM/Product/*.t

unit_test_product_all: $(PRODUCTALL)

pod_test:
	@$(PROVE) --norc t/*pod*.t

tidy:
	find . -name '*.p?.bak' -delete
	find . -not -path "./.git*" -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

doc:
	pod2markdown lib/BOM/Product/Contract.pm > README.md

cover:
	cover -delete
	PERL5OPT=-MBOM::Test HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer --norc -It/lib -rl $$(find t/unit -name "*.t" | grep -vE 'memtest|benchmark|ContractFinder')
	PERL5OPT=-MBOM::Test HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer --norc -It/lib -rl $$(find t/BOM -name "*.t" | grep -vE 'memtest|benchmark|ContractFinder')
	cover -report coveralls
	
unit:
	/etc/rmg/bin/prove -rlv --timer t/unit/
