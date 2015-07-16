TESTS=merlin_benchmark \
      SDFX_benchmark \
      SDEQ_benchmark \
      IH_benchmark \
      NTO_benchmark \
      OVRA_benchmark \

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

merlin_benchmark:
	prove -r t/run_quant_benchmark_test.pl --which=merlin

SDFX_benchmark:
	prove -r t/run_quant_benchmark_test.pl --which=sdfx

SDEQ_benchmark:
	prove -r t/run_quant_benchmark_test.pl --which=sdeq

IH_benchmark:
	prove -r t/run_quant_benchmark_test.pl --which=intraday_historical

NTO_benchmark:
	prove -r t/run_quant_benchmark_test.pl --which=nto

OVRA_benchmark:
	prove -r t/run_quant_benchmark_test.pl --which=ovra


tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

compile:
	prove -v -l t/BOM/002_autosyntax.t


