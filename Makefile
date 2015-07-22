TESTS=merlin_benchmark \
      SDFX_benchmark \
      SDEQ_benchmark \
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
	perl -Ilib t/run_quant_benchmark_test.pl --which=merlin

SDFX_benchmark_DJI:
	perl -Ilib t/run_quant_benchmark_test.pl --which=sdfx --file=DJI

SDEQ_benchmark_FCHI:
	perl -Ilib t/run_quant_benchmark_test.pl --which=sdeq --file=FCHI

SDEQ_benchmark_SPC:
	perl -Ilib t/run_quant_benchmark_test.pl --which=sdeq --file=SPC

SDEQ_benchmark_N225:
	perl -Ilib t/run_quant_benchmark_test.pl --which=sdeq --file=N225

SDEQ_benchmark_SSECOMP:
	perl -Ilib t/run_quant_benchmark_test.pl --which=sdeq --file=SSECOMP

SDEQ_benchmark_FTSE:
	perl -Ilib t/run_quant_benchmark_test.pl --which=sdeq --file=FTSE

OVRA_benchmark_:
	perl -Ilib t/run_quant_benchmark_test.pl --which=ovra


tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

compile:
	prove -v -l t/BOM/002_autosyntax.t


