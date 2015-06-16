ALTER SERVER cr  OPTIONS (SET host 'localhost');
ALTER SERVER dc  OPTIONS (SET host 'localhost');

ALTER USER MAPPING FOR postgres SERVER dc  OPTIONS (SET password 'letmein');
ALTER USER MAPPING FOR read SERVER dc      OPTIONS (SET password 'letmein');
ALTER USER MAPPING FOR write SERVER dc      OPTIONS (SET password 'letmein');

ALTER USER MAPPING FOR postgres SERVER cr  OPTIONS (SET password 'letmein');
ALTER USER MAPPING FOR master_write SERVER cr  OPTIONS (SET password 'letmein');
ALTER USER MAPPING FOR write SERVER cr  OPTIONS (SET password 'letmein');
ALTER USER MAPPING FOR read SERVER cr  OPTIONS (SET password 'letmein');


DROP USER MAPPING FOR postgres SERVER mx;
DROP USER MAPPING FOR read SERVER mx;
DROP USER MAPPING FOR master_write SERVER mx;
DROP USER MAPPING FOR write SERVER mx;
DROP SERVER mx;

DROP USER MAPPING FOR postgres SERVER mlt;
DROP USER MAPPING FOR read SERVER mlt;
DROP USER MAPPING FOR master_write SERVER mlt;
DROP USER MAPPING FOR write SERVER mlt;
DROP SERVER mlt;

DROP USER MAPPING FOR postgres SERVER vr;
DROP USER MAPPING FOR read SERVER vr;
DROP USER MAPPING FOR master_write SERVER vr;
DROP USER MAPPING FOR write SERVER vr;
DROP SERVER vr;

DROP USER MAPPING FOR postgres SERVER mf;
DROP USER MAPPING FOR read SERVER mf;
DROP USER MAPPING FOR master_write SERVER mf;
DROP USER MAPPING FOR write SERVER mf;
DROP SERVER mf;
