CORETESTS=unit_test_product_contract \
      unit_test_product_contract_settlement \
      unit_test_product_base \
      unit_test_product_model \
      unit_test_volatility \
      unit_test_offerings \

TESTS=test syntax

PRODUCTALL=unit_test_validation \
      memory_test \
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
P=/etc/rmg/bin/prove -lv --timer

ifeq ($(GITHUB_ACTIONS),true)
	EXTRA_ARGS = --merge --formatter TAP::Formatter::JUnit::PrintTxtStdout
else
	EXTRA_ARGS =
endif

PROVE=p () { $M; echo '$P' $(EXTRA_ARGS) "$$@"; $P $(EXTRA_ARGS) "$$@"; }; p

test_all: $(TESTS)

test: $(CORETESTS)

syntax_diff:
	@$(PROVE) --norc $$(ls t/*.t | grep -v syntax_all)

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
	@$(PROVE) -r t/BOM/Product/Validation/*.t

memory_test:
	@$(PROVE) -r t/BOM/Product/Validation/MemoryTest/

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

unit_test_product_except_validation_contract_pricing:
	@$(PROVE) t/BOM/Product/*.t -r t/BOM/Product/Model/ -r t/BOM/Product/Volatility/ -r t/BOM/Product/Offerings/

pod_test:
	@$(PROVE) --norc t/*pod*.t

tidy:
	find . -name '*.p?.bak' -delete
	find . -not -path "./.git*" -name '*.p[lm]' -o -name '*.t' | xargs perltidier -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

doc:
	pod2markdown lib/BOM/Product/Contract.pm > README.md

cover:
	cover -delete
	sed -i '1667,1668d' /home/git/binary-com/perl/lib/5.26.2/B/Deparse.pm
	PERL5OPT=-MBOM::Test HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --ignore-exit --timer --norc -It/lib -rl $$(find t/unit t/BOM -name "*.t" | grep -vE 'memtest|benchmark')
	cover -report coveralls

unit:
	@$(PROVE) -r t/unit/
