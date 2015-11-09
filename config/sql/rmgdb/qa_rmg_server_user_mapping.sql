ALTER SERVER dc OPTIONS (SET host 'localhost', SET dbname 'fog_regentmarkets');

ALTER USER MAPPING FOR postgres SERVER dc  OPTIONS (SET password 'mRX1E3Mi00oS8LG');
ALTER USER MAPPING FOR read SERVER dc      OPTIONS (SET password 'mRX1E3Mi00oS8LG');
ALTER USER MAPPING FOR write SERVER dc      OPTIONS (SET password 'mRX1E3Mi00oS8LG');
