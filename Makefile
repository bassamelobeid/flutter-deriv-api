TESTS=merlin_benchmark \
      SDFX_benchmark_major \
      SDFX_benchmark_minor \
      SDEQ_benchmark_OTC_DJI \
      SDEQ_benchmark_OTC_FCHI \
      SDEQ_benchmark_OTC_SPC \
      SDEQ_benchmark_OTC_N225 \
      SDEQ_benchmark_SSECOMP \
      OVRA_benchmark \

M=rm -f /tmp/l4p.log && [ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
P=/etc/rmg/bin/prove -v --timer -I$D/lib -I$D -I$D/t  -I/home/git/regentmarkets/bom-postgres/lib
L=|| { [ -t 1 -a "$$TRAVIS" != true ] && echo '\033[01;31msee also /tmp/l4p.log\033[00m' || cat /tmp/l4p.log; false; }
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@" $L; }; p

default:
	@echo "You must specify target. The following targets available:"
	@echo "  i18n         - extract translatable strings from the code"
	@echo "  test         - Run lib tests"
	@echo "  tidy         - Run perltidy"

syntax:
	/etc/rmg/bin/prove -l --norc t/002_autosyntax.t t/002_critic_check.t

test: $(TESTS)

merlin_benchmark:
	/etc/rmg/bin/perl -Ilib t/run_quant_benchmark_test.pl --which=merlin

SDFX_benchmark_major:
	/etc/rmg/bin/perl -Ilib t/run_quant_benchmark_test.pl --which=sdfx --file=major

SDFX_benchmark_minor:
	/etc/rmg/bin/perl -Ilib t/run_quant_benchmark_test.pl --which=sdfx --file=minor

SDEQ_benchmark_OTC_DJI:
	/etc/rmg/bin/perl -Ilib t/run_quant_benchmark_test.pl --which=sdeq --file=DJI

SDEQ_benchmark_OTC_FCHI:
	/etc/rmg/bin/perl -Ilib t/run_quant_benchmark_test.pl --which=sdeq --file=FCHI

SDEQ_benchmark_OTC_SPC:
	/etc/rmg/bin/perl -Ilib t/run_quant_benchmark_test.pl --which=sdeq --file=SPC

SDEQ_benchmark_OTC_N225:
	/etc/rmg/bin/perl -Ilib t/run_quant_benchmark_test.pl --which=sdeq --file=N225

SDEQ_benchmark_SSECOMP:
	/etc/rmg/bin/perl -Ilib t/run_quant_benchmark_test.pl --which=sdeq --file=SSECOMP

SDEQ_benchmark_OTC_FTSE:
	/etc/rmg/bin/perl -Ilib t/run_quant_benchmark_test.pl --which=sdeq --file=FTSE

OVRA_benchmark:
	/etc/rmg/bin/perl -Ilib t/run_quant_benchmark_test.pl --which=ovra


tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

compile:
	/etc/rmg/bin/prove -v -l t/BOM/002_autosyntax.t


