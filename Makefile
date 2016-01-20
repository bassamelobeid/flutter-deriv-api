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

stress1:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' & 
	sleep 10
	cd /home/git/regentmarkets/stress/websocket-bench; ./run.sh 2

stress2:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' & 
	sleep 10
	cd /home/git/regentmarkets/stress/websocket-bench; ./run.sh 2

stress3:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' & 
	sleep 10
	cd /home/git/regentmarkets/stress/websocket-bench; ./run.sh 2

stress4:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' & 
	sleep 10
	cd /home/git/regentmarkets/stress/websocket-bench; ./run.sh 2

stress5:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' & 
	sleep 10
	cd /home/git/regentmarkets/stress/websocket-bench; ./run.sh 2

stress6:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' & 
	sleep 10
	cd /home/git/regentmarkets/stress/websocket-bench; ./run.sh 2

stress7:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' & 
	sleep 10
	cd /home/git/regentmarkets/stress/websocket-bench; ./run.sh 2

stress8:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' & 
	sleep 10
	cd /home/git/regentmarkets/stress/websocket-bench; ./run.sh 2

stress9:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' & 
	sleep 10
	cd /home/git/regentmarkets/stress/websocket-bench; ./run.sh 2

stress10:
	cd /home/git/regentmarkets/bom-websocket-api; ./bin/binary_websocket_api.pl daemon  -l 'http://*:5004' & 
	sleep 10
	cd /home/git/regentmarkets/stress/websocket-bench; ./run.sh 2

test_avg_stress:
	cd /home/git/regentmarkets/stress/websocket-bench; bin/test_avg_stress $

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
