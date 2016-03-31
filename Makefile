v2:
	prove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/v2

v3:
	bash -e /tmp/travis-scripts/websocket_tests.sh

structure:
	prove --timer -I./lib  -I./t t/BOM/*.t

leaktest:
	prove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/leak/v3

run_bench:
	cd /home/git/regentmarkets/bom-websocket-api; perl -MBOM::Test ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' &
	perl -MBOM::Test  /home/git/regentmarkets/stress/websocket-bench/bin/r50_tick.pl &
	cd /home/git/regentmarkets/stress/websocket-bench; . misc/config.sh; bin/test_server_ready localhost 5004 && bin/run_bench $(STRESS_NUM)

run_avg_stress:
ifeq ($(INSTANCE_NO),1)
	cd /home/git/regentmarkets/stress/websocket-bench; . misc/config.sh; bin/test_avg_stress $(TRAVIS_BUILD_NUMBER)
else
	true
endif

wsstress: run_bench run_avg_stress

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
