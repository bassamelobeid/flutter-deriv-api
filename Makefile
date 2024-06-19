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

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=/etc/rmg/bin/prove -rvl --timer

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
	@$(PROVE) t/BOM/Product/Contract/

unit_test_product_contract_settlement:
	@$(PROVE) t/BOM/Product/Settlement/

unit_test_product_contract_extended:
	@$(PROVE) t/BOM/Product/ContractExtended/

unit_test_validation:
	@$(PROVE) t/BOM/Product/Validation/

memory_test:
	@$(PROVE) t/BOM/MemoryTest/

unit_test_volatility:
	@$(PROVE) t/BOM/Product/Volatility/

unit_test_product_model:
	@$(PROVE) t/BOM/Product/Model/

unit_test_pricing:
	@$(PROVE) t/BOM/Product/Pricing/

unit_test_intraday:
	@$(PROVE) t/BOM/Product/Pricing/Engine/IntradayHistorical

unit_test_offerings:
	@$(PROVE) t/BOM/Product/Offerings/

unit_test_product_base:
	@$(PROVE) t/BOM/Product/Base

unit_test_product_all: $(PRODUCTALL)

unit_test_product_except_validation_contract_pricing:
	@$(PROVE) t/BOM/Product/*.t t/BOM/Product/Model/ t/BOM/Product/Volatility/ t/BOM/Product/Offerings/

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
	@$(PROVE) t/unit/

contract:
	@$(PROVE) t/BOM/Product/Contract/

pricing:
	@$(PROVE) t/BOM/Product/Pricing/ t/BOM/Product/Validation/

product_others:
	@$(PROVE) $$(find t/BOM/Product -maxdepth 1 | grep -vE "/(Product|Contract|Pricing|Validation)$$")

