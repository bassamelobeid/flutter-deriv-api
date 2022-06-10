HOUR=$(date +%H)
if [[ "$HOUR" == "12" || "$HOUR" == "13" || $1 == "-now" ]]; then
	echo "ok"
else
	echo "bad"
fi
