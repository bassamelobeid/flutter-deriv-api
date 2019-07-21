M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
MOJO_LOG_LEVEL?=info
export MOJO_LOG_LEVEL
P=/etc/rmg/bin/prove --timer -v -rl

PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

accounts:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/accounts t/999_redis_keys.t

security:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/security t/999_redis_keys.t

pricing:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/pricing t/999_redis_keys.t

misc:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/misc t/999_redis_keys.t

structure:
	@$(PROVE) t

schema:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite t/999_redis_keys.t

subscriptions:
	@$(PROVE) --norc /home/git/regentmarkets/bom-websocket-tests/v3/subscriptions

test: structure schema accounts security pricing misc

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

rwildcard=$(foreach d,$(wildcard $1*),$(call rwildcard,$d/,$2) $(filter $(subst *,%,$2),$d))
msc_graphs = $(patsubst %.msc,%.msc.png,$(call rwildcard,,*.msc))
dot_graphs = $(patsubst %.dot,%.dot.png,$(call rwildcard,,*.dot))

doc: $(msc_graphs) $(dot_graphs)

%.msc.png: %.msc
	mscgen -T png -i $< -o $@

%.dot.png: %.dot
	dot -Tpng < $< > $@
