ALTER SERVER dc OPTIONS (SET host 'localhost', SET dbname 'fog_regentmarkets');

ALTER USER MAPPING FOR postgres SERVER dc  OPTIONS (SET password 'letmein');
ALTER USER MAPPING FOR read SERVER dc      OPTIONS (SET password 'letmein');
ALTER USER MAPPING FOR write SERVER dc      OPTIONS (SET password 'letmein');

