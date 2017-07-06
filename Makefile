M=[ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
export PERL5OPT=-MTest::FailWarnings=-allow_deps,1
P=/etc/rmg/bin/prove --timer -rl
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test:
	@$(PROVE) t/BOM/RPC/Cashier/20_transfer_between_accounts.t

json_schema_1:
	@$(PROVE) /home/git/regentmarkets/bom-rpc/t/schema_suite/suite.t :: suite01.conf

json_schema_2:
	@$(PROVE) /home/git/regentmarkets/bom-rpc/t/schema_suite/suite.t :: suite02.conf

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
