v2:
	forkprove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/v2

v3:
	bash -e /tmp/travis-scripts/websocket_tests.sh

structure:
	forkprove --timer -I./lib  -I./t t/BOM/*.t

leaktest:
	forkprove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/leak/v3

stress:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' &
	sleep 10
	sudo netstat -anlpt |grep 500
	cd /home/git/regentmarkets/stress;go run stress.go -insert 100;go run stress.go -workers 2 -noecho

wsstress:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' & 
	cd /home/git/regentmarkets/stress/websocket-bench; ./bin/bom-feed-listener-random.pl --no-pid-file &
	sleep 5
	#cd /home/git/regentmarkets/stress/websocket-bench; . misc/config.sh; bin/test_server_ready localhost 5004 && bin/run_bench $(STRESS_NUM)

test_avg_stress:
	cd /home/git/regentmarkets/stress/websocket-bench; . misc/config.sh; bin/test_avg_stress $(TRAVIS_BUILD_NUMBER)

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
