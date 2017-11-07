M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
MOJO_LOG_LEVEL?=info
export MOJO_LOG_LEVEL
P=/etc/rmg/bin/prove --timer -v -rl

PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

v3_1:
	@$(PROVE) $$(ls -1d /home/git/regentmarkets/bom-websocket-tests/v3/* | grep 'v3/\(0\|1\|2\|4\)')

v3_2:
	@$(PROVE) $$(ls -1d /home/git/regentmarkets/bom-websocket-tests/v3/* | grep 'v3/\(5\|6\|7\)')

v3_3:
	@$(PROVE) $$(ls -1d /home/git/regentmarkets/bom-websocket-tests/v3/* | grep 'v3/\(8\|9\)')

json_schemas:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/proposal.t
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/assets.t
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/accounts.t
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/copytrading.t
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/multiple_account.t

structure:
	@$(PROVE) t/*.t

test: structure v3_1 v3_2 v3_3 json_schemas

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
