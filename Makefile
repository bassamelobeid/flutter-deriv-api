M=[ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
export PERL5OPT=-MTest::FailWarnings=-allow_deps,1
D=$(CURDIR)
I=-I$D/lib -I$D -I$D/t -I/home/git/regentmarkets/bom-websocket-tests/lib
P=/etc/rmg/bin/prove --timer -r $I
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

v3_1:
	@$(PROVE) $$(ls -1d /home/git/regentmarkets/bom-websocket-tests/v3/* | grep 'v3/\(0\|1\|2\|4\)')

v3_2:
	@$(PROVE) $$(ls -1d /home/git/regentmarkets/bom-websocket-tests/v3/* | grep 'v3/\(5\|6\|7\)')

v3_3:
	@$(PROVE) $$(ls -1d /home/git/regentmarkets/bom-websocket-tests/v3/* | grep 'v3/\(8\|9\)')

json_schema:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/suite.t

loadtest:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/loadtest.t

structure:
	@$(PROVE) t/*.t

leaktest:
	@$(PROVE) t/leak/v3

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
