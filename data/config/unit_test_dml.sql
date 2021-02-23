--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

--SET session_replication_role TO 'replica';


SET search_path = audit, pg_catalog;

SET search_path = betonmarkets, pg_catalog;

COPY broker_code (broker_code) FROM stdin;
CBET
VRT
MLT
MF
NF
VRTM
MX
MXR
VRTU
FOG
UK
TEST
FTB
VRTF
CR
VRTC
VRTN
VRTR
VRTS
WS
RCP
VRTP
FOTC
VRTO
EM
VRTE
BFT
VRTB
VRTJ
JP
CH
VRCH
DW 
VRDW
\.

--
-- Data for Name: client; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

COPY client (loginid, binary_user_id, client_password, first_name, last_name, email, allow_login, broker_code, residence, citizen, salutation, address_line_1, address_line_2, address_city, address_state, address_postcode, phone, date_joined, latest_environment, secret_question, secret_answer, restricted_ip_address, gender, cashier_setting_password, date_of_birth, small_timer, comment, myaffiliates_token, myaffiliates_token_registered, checked_affiliate_exposures, custom_max_acbal, custom_max_daily_turnover, custom_max_payout, payment_agent_withdrawal_expiration_date, first_time_login, source, non_pep_declaration_time) FROM stdin;
MLT0012	110	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Bond Lim	bond@regentmarkets.com	t	MLT	au	au	Mr	address		tiwn		12341	+621111111111	2009-02-23 07:33:00	23-Feb-09 07h33GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4		m		1988-09-12	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2019-09-13 
MLT0013	111	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	ivan@regentmarkets.com	t	MLT	au	au	Mr	test	test  	test		12345	+6111111111	2009-08-13 09:34:00	13-Aug-09 09h34GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=				m		1932-09-07	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-08-13 
MLT0014	112	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	bond@regentmarkets.com	t	MLT	au	au	Mr	test	test  	test		11111	+61111231411	2009-08-13 09:43:00	13-Aug-09 09h43GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=				m		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N  	2009-08-12 
MLT0015	113	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	bond@regentmarkets.com	t	MLT	au	au	Mr	test	test  	test		11111	+61111231411	2009-08-31 08:00:00	31-Aug-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=				m		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-08-11 
MLT0016	114	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	bond@regentmarkets.com	t	MLT	au	au	Mr	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=				m		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\ 	2009-07-13 
MX0012	115	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Bond Lim	bond@regentmarkets.com	t	MX	au	au	Mr	address		tiwn		12341	+621111111111	2009-02-23 07:33:00	23-Feb-09 07h33GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4		m		1988-09-12	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
MX0013	116	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	ivan@regentmarkets.com	t	MX	au	au	Mr	test	test  	test		12345	+6111111111	2009-08-13 09:34:00	13-Aug-09 09h34GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4		m		1932-09-07	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
MX0014	117	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	bond@regentmarkets.com	t	MX	au	au	Mr	test	test  	test		11111	+61111231411	2009-08-13 09:43:00	13-Aug-09 09h43GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		m		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
MX0015	118	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	bond@regentmarkets.com	t	MX	au	au	Mr	test	test  	test		11111	+61111231411	2009-08-31 08:00:00	31-Aug-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		m		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
MX0016	119	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	bond@regentmarkets.com	t	MX	au	au	Mr	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		m		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
MLT0017	120	960f984285701c6d8dba5dc71c35c55c0397ff276b06423146dde88741ddf1af	Pornchai	Chuengsawat	felix@regentmarkets.com	t	MLT	th	th	Mr	97/13 Tararom vill., Sukhapiban 3 RD., Sapansoong,		Bangkok		10240	123456789	\N	25-Dec-07 13h33GMT 124.120.26.75 Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1; SV1; .NET CLR 1.1.4322; .NET CLR 2.0.50727) LANG=EN SKIN=	What is your pet	::ecp::52616e646f6d49563336336867667479e29117e32952b1c56491a644700d6963		m		1974-05-15	yes		\N	f	f	\N	\N	\N	\N	t	\ 	2009-09-13 
CR0001	121	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	CR	gb	gb	Mr	test	test  	test		te12st	44999999999	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m		1982-07-17	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0002	122	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	CR	gb	gb	Mr	test1	test2  	test		te12st	44999999999	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m		1982-07-17	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0003	123	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	CR	gb	gb	Mr	test1	test2  	test		te12st	44999999999	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m		1982-07-17	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0004	124	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	CR	gb	gb	Mr	test1	test2  	test		te12st	44999999999	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m		1982-07-17	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0005	125	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	CR	gb	gb	Mr	test1	test2  	test		te12st	44999999999	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m		1982-07-17	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0006	126	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	CR	gb	gb	Mr	test1	test2  	test		te12st	44999999999	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m		1982-07-17	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0007	127	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	CR	gb	gb	Mr	test1	test2  	test		te12st	44999999999	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m		1982-07-17	notarised		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0008	128	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	CR	gb	gb	Mr	test1	test2  	test		te12st	44999999999	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m		1982-07-17	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0009	129	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	CR	de	gb	Mr	test1	test2  	test		te12st	00869145685791	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m	ILOVEBUGS	1982-07-17	notarised		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0010	130	$1$s5fRSVzb$E9UlOOXKoBWJApUuxjdas.	mohammad	shamsi	fuguo@regentmarkets.com	t	CR	ir	ir	Mr	somewhere	somewhere  	Tehran		121212	+9822424242	2008-12-17 02:25:00	17-Dec-08 02h25GMT 192.168.12.51 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9b5) Gecko/2008052519 CentOS/3.0b5-0.beta5.6.el5.centos Firefox/3.0b5 LANG=EN SKIN=	Memorable town city	::ecp::52616e646f6d495633363368676674799a9ef5e1e303e68c		m		1980-03-12	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-12-02 
CR0011	131	8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92	Amy	mimi	shuwnyuan@yahoo.com	t	CR	au	au	Ms	53, Jln Address 1	Jln Address 2	Segamat		85010	069782001	2009-02-20 06:08:00	16-Jul-09 08h18GMT 192.168.12.62 Mozilla 5.0 (X11; U; Linux i686; en-US; rv:1.8.1.14) Gecko 20080404 Firefox 2.0.0.14 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d49563336336867667479f75f67cfc8179b31	192.168.0.1	f		1980-01-01	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-10-06 
CR0012	132	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Bond Lim	bond@regentmarkets.com	t	CR	au	au	Mr	address		tiwn		12341	+621111111111	2009-02-23 07:33:00	23-Feb-09 07h33GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4		m		1988-09-12	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-01-23 
CR0013	133	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	ivan@regentmarkets.com	t	CR	au	au	Mr	test	test  	test		12345	+6111111111	2009-08-13 09:34:00	13-Aug-09 09h34GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4		m		1932-09-07	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-09 
CR0014	134	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	bond@regentmarkets.com	t	CR	au	au	Mr	test	test  	test		11111	+61111231411	2009-08-13 09:43:00	13-Aug-09 09h43GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		m		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-02-03 
CR0015	135	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Nick	Marden	nick@regentmarkets.com	t	CR	au	au	Mr	test	test  	test		11111	+61111231411	2009-08-31 08:00:00	31-Aug-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		m		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-21 
CR0016	136	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	bond@regentmarkets.com	t	CR	au	au	Mr	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		m		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-03 
CR0017	137	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	bond@regentmarkets.com	t	CR	au	au	Mr	test	test  	test		12345	+611111111111	2009-08-19 09:21:00	19-Aug-09 09h21GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.1.2) Gecko/20090729 Firefox/3.5.2 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4		m		1922-02-01	notarised		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0020	138	8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92	shuwnyuan	tee	shuwnyuan@regentmarkets.com	t	CR	au	my	Ms	53, Jln Address 1	Jln Address 2 Jln Address 3 Jln Address 4	Segamat		85010	069782001	2009-02-20 06:08:00	16-Jul-09 08h18GMT 192.168.12.62 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.8.1.14) Gecko/20080404 Firefox/2.0.0.14 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d49563336336867667479f75f67cfc8179b31	192.168.0.1	f		1980-01-01	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0021	139	8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92	shuwnyuan	tee	shuwnyuan@regentmarkets.com	t	CR	au	my	Ms	53, Jln Address 1	Jln Address 2 Jln Address 3 Jln Address 4	Segamat		85010	069782001	2009-02-20 06:08:00	16-Jul-09 08h18GMT 192.168.12.62 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.8.1.14) Gecko/20080404 Firefox/2.0.0.14 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d49563336336867667479f75f67cfc8179b31	192.168.0.1	f		1980-01-01	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0022	140	48elKjgSSiaeD5v233716ab5	†•…‰™œŠŸž€ΑΒΓΔΩαβγδωАБВГДабвгд∀∂∈ℝ∧∪≡∞↑↗↨↻⇣┐┼╔╘░►☺	♀ﬁ�⑀₂ἠḂӥẄɐː⍎אԱა Καλημέρα κόσμε, コンニチハ	TanChongGee@yahoo.com	t	CR	gb		Mr							\N	28-Sep-07 02h09GMT 192.168.12.59 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.8.1.6) Gecko/20070813 Fedora/2.0.0.6-3.fc8 Firefox/2.0.0.6 LANG=EN SKIN=				m		1975-02-16	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0023	141	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	shuwnyuan	tee	sy@regentmarkets.com	t	CR	au	au	Ms	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		f		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0024	142	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	shuwnyuan	tee	sy@regentmarkets.com	t	CR	au	au	Ms	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		f		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0025	143	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	shuwnyuan	tee	sy@regentmarkets.com	t	CR	au	au	Ms	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		f		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0026	144	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	bond@regentmarkets.com	t	CR	au	au	Mr	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		m		1953-08-06	yes		XXXXX	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0027	145	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	Bond	Lim	bond@regentmarkets.com	t	CR	au	au	Mr	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		m		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
CR0028	146	6ca13d52ca70c883e0f0bb101e425a89e8624de51db2d2392593af6a84118090	Polar	Bear	sokting@regentmarkets.com	t	CR	aq	aq	Mr	Igloo 1	Polar street  	Bearcity		11111	+6712345678	2009-11-18 08:00:00	18-Nov-09 02h50GMT 192.168.12.43 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9b5) Gecko/2008052519 CentOS/3.0b5-0.beta5.6.el5.centos Firefox/3.0b5 LANG=EN SKIN=	Favourite dish	::ecp::52616e646f6d49563336336867667479058d7cb3c47cb130		m		1919-01-01	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-08-13 
CR0029	147	6ca13d52ca70c883e0f0bb101e425a89e8624de51db2d2392593af6a84118090	Polar	Bear	sokting@regentmarkets.com	t	CR	aq	aq	Mr	Igloo 1	Polar street  	Bearcity		11111	+6712345678	2009-11-18 08:00:00	18-Nov-09 02h50GMT 192.168.12.43 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9b5) Gecko/2008052519 CentOS/3.0b5-0.beta5.6.el5.centos Firefox/3.0b5 LANG=EN SKIN=	Favourite dish	::ecp::52616e646f6d49563336336867667479058d7cb3c47cb130		m		1919-01-01	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-08-13 
CR0030	148	6ca13d52ca70c883e0f0bb101e425a89e8624de51db2d2392593af6a84118090	Polar	Bear	sokting@regentmarkets.com	t	CR	aq	aq	Mr	Igloo 1	Polar street  	Bearcity		11111	+6712345678	2009-11-18 08:00:00	18-Nov-09 02h50GMT 192.168.12.43 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9b5) Gecko/2008052519 CentOS/3.0b5-0.beta5.6.el5.centos Firefox/3.0b5 LANG=EN SKIN=	Favourite dish	::ecp::52616e646f6d49563336336867667479058d7cb3c47cb130		m		1919-01-01	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-08-13 
CR0031	149	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	CR	de	gb	Mr	test1	test2  	test		te12st	00869145685791	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m	ILOVEBUGS	1982-07-17	notarised		\N	f	f	\N	\N	\N	\N	t	\N 	2010-05-13 
CR0032	150	8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92	tee	shuwnyuan	shuwnyuan@regentmarkets.com	t	CR	au	au	Ms	ADDR 1	ADDR 2	Segamat		85010	+60123456789	2010-05-12 06:40:11	12-May-10 06:40:11GMT 127.0.0.1  LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d49563336336867667479f75f67cfc8179b31		f		1980-01-01	no		\N	f	f	\N	\N	\N	\N	t	\N 	2009-10-13 
CR0099	151	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	shuwnyuan	tee	sy@regentmarkets.com	t	CR	au	au	Ms	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		f		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-07-31 
CR0100	152	 ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	shuwnyuan	tee	sy@regentmarkets.com	t	CR	au	au	Ms	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		f		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-07-31 
UK1001	153	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	UK	de	gb	Mr	test1	test2  	test		te12st	00869145685791	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m	ILOVEBUGS	1982-07-17	notarised		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
VRTC1001	154	ff3LtC2i6ikST/IU5e7e0011	Calum	Halcrow	dummy@regentmarkets.com	t	VRTC	de	gb	Mr	test1	test2  	test		te12st	00869145685791	\N	8-Feb-07 08h19GMT 127.0.0.1  LANG=EN	Favourite dish	::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795		m	ILOVEBUGS	1982-07-17	notarised		\N	f	f	\N	\N	\N	\N	t	\N 	2009-09-13 
MX1001	155	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	shuwnyuan	tee	sy@regentmarkets.com	t	MX	au	au	Ms	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		f		1953-08-06	yes		XXXX	f	f	\N	\N	\N	\N	t	\N 	2009-07-13 
CR2002	156	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	shuwnyuan	tee	sy@regentmarkets.com	t	CR	au	au	Ms	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		f		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-08-13 
CR3003	157	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	shuwnyuan	tee	sy@regentmarkets.com	t	CR	au	au	Ms	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		f		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-07-13 
CR9999	158	ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544	shuwnyuan	tee	sy@regentmarkets.com	t	CR	au	au	Ms	test	test  	test		11111	+61111231411	2009-07-31 08:00:00	31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=	Mother's maiden name	::ecp::52616e646f6d4956333633686766747950fe7262c4589c41		f		1953-08-06	yes		\N	f	f	\N	\N	\N	\N	t	\N 	2009-08-13 
CR1500	159	super_secret_password	Bill	Mac	bill@regentmarkets.com	t	CR	au	au	Mr	add1	add2	addcity	addstate	addpostcode	+012345678900	2017-05-01	empty_environment	Mother's maiden name	MOM	no_restriction	m	cash_password	1985-01-01	yes	no comment	\N	f	f	\N	\N	\N	\N	t	\N 	2017-05-13 
CR0101	160	super_secret_password	Johny	NoPhone1	nophone@regentmarkets.com	t	CR	au	au	Mr	add1	add2	addcity	addstate	addpostcode		2017-05-01	empty_environment	Mother's maiden name	MOM	no_restriction	m	cash_password	1985-01-01	yes	no comment	\N	f	f	\N	\N	\N	\N	t	\N 	2017-05-13 
CR0102	162	super_secret_password	Johny	NoPhone2	nophone@regentmarkets.com	t	CR	au	au	Mr	add1	add2	addcity	addstate	addpostcode	+	2017-05-01	empty_environment	Mother's maiden name	MOM	no_restriction	m	cash_password	1985-01-01	yes	no comment	\N	f	f	\N	\N	\N	\N	t	\N 	2017-09-13 
CR0103	163	super_secret_password	Johny	NoPhone3	nophone@regentmarkets.com	t	CR	au	au	Mr	add1	add2	addcity	addstate	addpostcode	abc	2017-05-01	empty_environment	Mother's maiden name	MOM	no_restriction	m	cash_password	1985-01-01	yes	no comment	\N	f	f	\N	\N	\N	\N	t	\N 	2017-06-13 
CR0111	164	super_secret_password	Mathew	NoLastName	dummy@regentmarkets.com	t	CR	au	au	Mr	add1	add2	addcity	addstate	addpostcode	abc	2017-05-01	empty_environment	Mother's maiden name	MOM	no_restriction	m	cash_password	1985-01-01	yes	no comment	\N	f	f	\N	\N	\N	\N	t	\N 	2020-05-04
\.

SET search_path = transaction, pg_catalog;

--
-- Data for Name: account; Type: TABLE DATA; Schema: transaction; Owner: postgres
--
COPY account (id, client_loginid, currency_code, balance, is_default, last_modified) FROM stdin;
1201	CR0011	USD	0.0000	t	\N
1203	CR9999	USD	0.0000	t	\N
200419	CR0012	USD	0.0000	t	\N
200499	CR0005	USD	136.8000	t	2016-04-12 12:57:59.427972
200039	MX1001	GBP	4191.0500	t	2016-04-12 12:57:59.183541
200099	MX0013	USD	4.9600	t	2016-04-12 12:57:59.187787
200199	MLT0013	USD	4.9600	t	2016-04-12 12:57:59.192076
200679	CR0024	GBP	54909.0000	t	2016-04-12 12:57:59.535948
200739	CR0017	GBP	300.0000	t	2016-04-12 12:57:59.538699
200219	CR0031	USD	4500.0000	t	2016-04-12 12:57:59.199612
200259	CR0029	USD	6280.0000	t	2016-04-12 12:57:59.205593
200279	CR0028	USD	490.0000	t	2016-04-12 12:57:59.214225
200299	CR0027	USD	720.0000	t	2016-04-12 12:57:59.215537
200339	CR0025	USD	35.0000	t	2016-04-12 12:57:59.356559
200699	CR0023	GBP	64909.0000	t	2016-04-12 12:57:59.558544
200779	CR0015	GBP	20.0000	t	2016-04-12 12:57:59.559801
200359	CR0021	USD	1505.0000	t	2016-04-12 12:57:59.46966
200539	MX0015	GBP	20.0000	t	2016-04-12 12:57:59.472143
200799	CR0014	GBP	290.3000	t	2016-04-12 12:57:59.566947
200519	MX0016	GBP	6880.0000	t	2016-04-12 12:57:59.478957
200379	CR0016	USD	274.3400	t	2016-04-12 12:57:59.376228
200479	CR0006	USD	5.0000	t	2016-04-12 12:57:59.377409
200639	CR0030	GBP	543.0500	t	2016-04-12 12:57:59.662487
200599	MLT0015	GBP	20.0000	t	2016-04-12 12:57:59.482623
200559	MX0014	GBP	247.1000	t	2016-04-12 12:57:59.484888
200579	MLT0016	GBP	6880.0000	t	2016-04-12 12:57:59.486184
200859	MLT0017	EUR	9930.0000	t	2016-04-12 12:57:59.667057
200619	MLT0014	GBP	247.1000	t	2016-04-12 12:57:59.49429
200319	CR0026	USD	274.3400	t	2016-04-12 12:57:59.398775
200399	CR0013	USD	4.9600	t	2016-04-12 12:57:59.407673
200439	CR0009	USD	5000.0000	t	2016-04-12 12:57:59.414521
1202	CR0010	EUR	8962.8000	t	2016-04-12 12:57:59.773696
200919	MX0012	GBP	5.0400	t	2016-04-12 12:57:59.774936
200939	MLT0012	AUD	5.0400	t	2016-04-12 12:57:59.7762
201039	CR0099	USD	20.0000	t	2016-04-12 12:57:59.77743
200459	CR0008	USD	469355.9000	t	2016-04-12 12:57:59.422959
201079	CR2002	USD	10.0000	t	2016-04-12 12:57:59.778634
201099	CR1500	BTC	0.00001	t	2017-05-03 12:34:56.987654
201119	CR0111	USD	100.00	t	2020-05-04 09:05:16.019524
\.


-- populate bet.contract_group with somehow sensible values
INSERT INTO bet.contract_group(bet_type, contract_group)
SELECT bet_type, coalesce(substring(table_name from '^(.*?)_bet$'), table_name)
  FROM bet.bet_dictionary
    ON CONFLICT (bet_type) DO NOTHING;

SET search_path = bet, pg_catalog;

-- At some point, much of what is being inserted as open bets should be moved into fmb_open, but for now we just need one test case in there
-- Theoretically, all open bets should be able to move, but if that breaks tests, that is an exercise for another day.
COPY financial_market_bet_open (id, purchase_time, account_id, underlying_symbol, payout_price, buy_price, sell_price, start_time, expiry_time, settlement_time, expiry_daily, is_expired, is_sold, bet_class, bet_type, remark, short_code, sell_time, fixed_expiry, tick_count) FROM stdin;
300000	2017-03-09 02:16:00	1202	frxEURCHF	50	25	\N	2017-03-09 06:00:00	2017-03-09 07:00:00	2017-03-09 07:00:00	f	t	f	higher_lower_bet	CALL	\N	CALL_FRXEURCHF_50_5_MARCH_09_6_7	\N	\N	\N
300020	2017-03-09 03:16:00	1202	frxEURCHF	50	25	\N	2017-03-09 07:00:00	2017-03-09 08:00:00	2017-03-09 08:00:00	f	t	f	higher_lower_bet	CALL	\N	CALL_FRXEURCHF_50_5_MARCH_09_7_8	\N	\N	\N
300040	2017-03-09 03:16:00	200039	frxEURCHF	50	25	\N	2017-03-09 07:00:00	2017-03-09 08:00:00	2017-03-09 08:00:00	f	t	f	higher_lower_bet	CALL	\N	CALL_FRXEURCHF_50_5_MARCH_09_7_8	\N	\N	\N
300060	2017-03-09 04:16:00	200039	frxEURCHF	50	25	\N	2017-03-09 07:00:00	2017-03-09 09:00:00	2017-03-09 10:00:00	f	t	f	higher_lower_bet	CALL	\N	CALL_FRXEURCHF_50_5_MARCH_09_9_10	\N	\N	\N
300080	2017-03-09 04:16:00	200039	frxEURCHF	50	25	\N	2017-03-09 07:00:00	2017-03-09 09:00:00	2017-03-09 10:00:00	f	t	f	higher_lower_bet	CALL	\N	CALL_FRXEURCHF_50_5_MARCH_09_9_10	\N	\N	\N
\.

--
-- Data for Name: financial_market_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

COPY financial_market_bet (id, purchase_time, account_id, underlying_symbol, payout_price, buy_price, sell_price, start_time, expiry_time, settlement_time, expiry_daily, is_expired, is_sold, bet_class, bet_type, remark, short_code, sell_time, fixed_expiry, tick_count) FROM stdin;
201459	2005-09-21 06:26:00	200359	frxUSDJPY	40	20	38	2005-09-21 06:26:00	2005-09-21 06:26:05	2005-09-21 06:26:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.664,111.656,111.667,111.661,111.66,111.689,	RUNBET_DOUBLEUP_USD400_frxUSDJPY_5	2005-09-21 06:26:05	\N	\N
201519	2005-09-21 06:27:00	200359	frxUSDJPY	80	40	76	2005-09-21 06:27:00	2005-09-21 06:27:05	2005-09-21 06:27:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.643,111.632,111.635,111.632,111.638,111.647,	RUNBET_DOUBLEUP_USD800_frxUSDJPY_5	2005-09-21 06:27:05	\N	\N
201599	2005-09-21 06:29:00	200359	frxUSDJPY	40	20	38	2005-09-21 06:29:00	2005-09-21 06:29:05	2005-09-21 06:29:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.564,111.574,111.576,111.57,111.574,111.572,	RUNBET_DOUBLEUP_USD400_frxUSDJPY_5	2005-09-21 06:29:05	\N	\N
201619	2005-09-21 06:29:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:29:00	2005-09-21 06:29:05	2005-09-21 06:29:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.576,111.588,111.578,111.568,111.562,111.581,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:29:05	\N	\N
201659	2005-09-21 06:30:00	200359	frxUSDJPY	40	20	38	2005-09-21 06:30:00	2005-09-21 06:30:05	2005-09-21 06:30:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=111.577,111.584,111.583,111.575,111.571,111.569,	RUNBET_DOUBLEDOWN_USD400_frxUSDJPY_5	2005-09-21 06:30:05	\N	\N
201839	2005-09-21 06:37:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:37:00	2005-09-21 06:37:05	2005-09-21 06:37:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.567,111.568,111.564,111.569,111.572,111.571,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:37:05	\N	\N
201859	2005-09-21 06:38:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:38:00	2005-09-21 06:38:05	2005-09-21 06:38:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.583,111.595,111.603,111.595,111.598,111.591,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:38:05	\N	\N
201879	2005-09-21 06:38:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:38:00	2005-09-21 06:38:05	2005-09-21 06:38:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.598,111.604,111.602,111.607,111.594,111.623,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:38:05	\N	\N
201899	2005-09-21 06:39:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:39:00	2005-09-21 06:39:05	2005-09-21 06:39:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.621,111.617,111.608,111.618,111.613,111.627,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:39:05	\N	\N
201919	2005-09-21 06:39:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:39:00	2005-09-21 06:39:05	2005-09-21 06:39:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.627,111.631,111.635,111.621,111.654,111.658,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:39:05	\N	\N
201939	2005-09-21 06:40:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:40:00	2005-09-21 06:40:05	2005-09-21 06:40:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.634,111.644,111.65,111.634,111.63,111.642,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:40:05	\N	\N
201979	2005-09-21 06:40:00	200359	frxUSDJPY	40	20	38	2005-09-21 06:40:00	2005-09-21 06:40:05	2005-09-21 06:40:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=111.61,111.62,111.611,111.585,111.587,111.593,	RUNBET_DOUBLEDOWN_USD400_frxUSDJPY_5	2005-09-21 06:40:05	\N	\N
201999	2005-09-21 06:40:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:40:00	2005-09-21 06:40:05	2005-09-21 06:40:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=111.554,111.555,111.543,111.538,111.554,111.54,	RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5	2005-09-21 06:40:05	\N	\N
202019	2005-09-21 06:41:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:41:00	2005-09-21 06:41:05	2005-09-21 06:41:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=111.538,111.557,111.543,111.53,111.536,111.53,	RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5	2005-09-21 06:41:05	\N	\N
202099	2005-09-21 06:42:00	200359	frxUSDJPY	200	100	190	2005-09-21 06:42:00	2005-09-21 06:42:05	2005-09-21 06:42:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.503,111.498,111.491,111.489,111.488,111.514,	RUNBET_DOUBLEUP_USD2000_frxUSDJPY_5	2005-09-21 06:42:05	\N	\N
202119	2005-09-21 06:42:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:42:00	2005-09-21 06:42:05	2005-09-21 06:42:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.491,111.503,111.515,111.499,111.495,111.503,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:42:05	\N	\N
202179	2005-09-21 06:43:00	200359	frxUSDJPY	80	40	76	2005-09-21 06:43:00	2005-09-21 06:43:05	2005-09-21 06:43:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.48,111.479,111.49,111.485,111.493,111.499,	RUNBET_DOUBLEUP_USD800_frxUSDJPY_5	2005-09-21 06:43:05	\N	\N
202199	2005-09-21 06:44:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:44:00	2005-09-21 06:44:05	2005-09-21 06:44:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.49,111.499,111.496,111.497,111.493,111.492,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:44:05	\N	\N
202319	2005-09-21 06:46:00	200359	frxUSDJPY	250	125	237.5	2005-09-21 06:46:00	2005-09-21 06:46:05	2005-09-21 06:46:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=111.518,111.514,111.529,111.523,111.525,111.513,	RUNBET_DOUBLEDOWN_USD2500_frxUSDJPY_5	2005-09-21 06:46:05	\N	\N
202979	2009-07-31 23:49:00	200679	frxUSDJPY	20	10	19	2009-07-31 23:49:00	2009-07-31 23:49:05	2009-07-31 23:49:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=114.136,114.139,114.101,114.104,114.138,114.125,	RUNBET_DOUBLEDOWN_GBP200_frxUSDJPY_5	2009-07-31 23:49:05	\N	\N
200499	2005-09-21 06:16:00	200359	frxUSDJPY	10	5	9.5	2005-09-21 06:16:00	2005-09-21 06:16:05	2005-09-21 06:16:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.658,111.656,111.665,111.67,111.662,111.66,	RUNBET_DOUBLEUP_USD100_frxUSDJPY_5	2005-09-21 06:16:05	\N	\N
200639	2005-09-21 06:16:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:16:00	2005-09-21 06:16:05	2005-09-21 06:16:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=111.669,111.656,111.676,111.66,111.658,111.664,	RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5	2005-09-21 06:16:05	\N	\N
200799	2005-09-21 06:18:00	200359	frxUSDJPY	40	20	38	2005-09-21 06:18:00	2005-09-21 06:18:05	2005-09-21 06:18:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=111.686,111.691,111.703,111.672,111.685,111.673,	RUNBET_DOUBLEDOWN_USD400_frxUSDJPY_5	2005-09-21 06:18:05	\N	\N
200819	2005-09-21 06:18:00	200359	frxUSDJPY	10	5	9.5	2005-09-21 06:18:00	2005-09-21 06:18:05	2005-09-21 06:18:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=111.691,111.68,111.681,111.703,111.69,111.686,	RUNBET_DOUBLEDOWN_USD100_frxUSDJPY_5	2005-09-21 06:18:05	\N	\N
200879	2005-09-21 06:20:00	200359	frxUSDJPY	30	15	28.5	2005-09-21 06:20:00	2005-09-21 06:20:05	2005-09-21 06:20:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.68,111.688,111.697,111.692,111.691,111.684,	RUNBET_DOUBLEUP_USD300_frxUSDJPY_5	2005-09-21 06:20:05	\N	\N
200999	2005-09-21 06:21:00	200359	frxUSDJPY	40	20	38	2005-09-21 06:21:00	2005-09-21 06:21:05	2005-09-21 06:21:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=111.675,111.661,111.671,111.677,111.67,111.671,	RUNBET_DOUBLEDOWN_USD400_frxUSDJPY_5	2005-09-21 06:21:05	\N	\N
201059	2005-09-21 06:21:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:21:00	2005-09-21 06:21:05	2005-09-21 06:21:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=111.667,111.674,111.665,111.666,111.662,111.659,	RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5	2005-09-21 06:21:05	\N	\N
201119	2005-09-21 06:22:00	200359	frxUSDJPY	40	20	38	2005-09-21 06:22:00	2005-09-21 06:22:05	2005-09-21 06:22:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.662,111.675,111.67,111.672,111.66,111.673,	RUNBET_DOUBLEUP_USD400_frxUSDJPY_5	2005-09-21 06:22:05	\N	\N
201139	2005-09-21 06:22:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:22:00	2005-09-21 06:22:05	2005-09-21 06:22:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.666,111.671,111.679,111.677,111.697,111.678,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:22:05	\N	\N
201199	2005-09-21 06:23:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:23:00	2005-09-21 06:23:05	2005-09-21 06:23:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.662,111.676,111.677,111.675,111.677,111.676,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:23:05	\N	\N
201259	2005-09-21 06:24:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:24:00	2005-09-21 06:24:05	2005-09-21 06:24:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.672,111.666,111.668,111.66,111.669,111.679,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:24:05	\N	\N
201299	2005-09-21 06:24:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:24:00	2005-09-21 06:24:05	2005-09-21 06:24:05	f	t	t	run_bet	RUNBET_DOUBLEUP	frxUSDJPY forecast=UP Run=111.671,111.674,111.688,111.68,111.685,111.676,	RUNBET_DOUBLEUP_USD200_frxUSDJPY_5	2005-09-21 06:24:05	\N	\N
201419	2005-09-21 06:25:00	200359	frxUSDJPY	20	10	19	2005-09-21 06:25:00	2005-09-21 06:25:05	2005-09-21 06:25:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=111.669,111.664,111.655,111.657,111.654,111.65,	RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5	2005-09-21 06:25:05	\N	\N
202359	2009-07-31 08:21:00	200519	frxXAUUSD	10000	3140	0	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
200139	2009-08-14 07:19:00	200099	frxGBPJPY	30	15.04	0	2009-08-14 07:19:52	2009-08-14 07:20:22	2009-08-14 07:20:22	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 intradaytime= theo=1	CALL_FRXGBPJPY_30_14_AUG_09_S30_07H1952	2009-08-14 07:20:22	\N	\N
200379	2009-08-14 07:19:00	200199	frxGBPJPY	30	15.04	0	2009-08-14 07:19:52	2009-08-14 07:20:22	2009-08-14 07:20:22	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 intradaytime= theo=1	CALL_FRXGBPJPY_30_14_AUG_09_S30_07H1952	2009-08-14 07:20:22	\N	\N
200439	2009-11-18 08:46:00	200279	frxEURUSD	10	30	0	2009-10-20 00:00:00	2009-10-21 00:00:00	2009-10-21 23:59:59	f	t	t	legacy_bet	DOUBLEONETOUCH	theo=5.97 trade=7.26 recalc=7.24 win=10 [MarkupEngine::Hedge] S=0.9126 r=0.0113 q=0.01326 t=0.00447761288685946 H=0.9163 L=0.9107 iv=0.191 (0.470343699687832,0.724264579356303,0.597304139522068,buy,FM=0) delta=-0.153374253450337 vega=0.0368378823608042 theta=-1.12652750894949 gamma=2.25702621452758 theo=5.97 spot_time=1256028394 	DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107	2009-10-21 23:59:59	\N	\N
200459	2009-10-20 08:46:00	200299	frxEURUSD	10	300	0	2009-10-20 00:00:00	2009-10-21 00:00:00	2009-10-21 23:59:59	f	t	t	legacy_bet	DOUBLEONETOUCH	theo=5.97 trade=7.26 recalc=7.24 win=10 [MarkupEngine::Hedge] S=0.9126 r=0.0113 q=0.01326 t=0.00447761288685946 H=0.9163 L=0.9107 iv=0.191 (0.470343699687832,0.724264579356303,0.597304139522068,buy,FM=0) delta=-0.153374253450337 vega=0.0368378823608042 theta=-1.12652750894949 gamma=2.25702621452758 theo=5.97 spot_time=1256028394 	DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107	2009-10-21 23:59:59	\N	\N
200659	2007-04-16 02:01:00	200339	frxEURUSD	10	5	10	2007-04-16 02:20:00	2007-04-16 02:30:00	2007-04-16 02:30:00	f	t	t	higher_lower_bet	CALL	\N	CALL_FRXEURUSD_10_16_APR_07_2H2_2H3	2007-04-16 02:30:00	\N	\N
200579	2007-04-16 01:48:00	200339	frxGBPJPY	10	5	10	2007-04-16 05:50:00	2007-04-16 06:00:00	2007-04-16 06:00:00	f	t	t	higher_lower_bet	PUT	\N	PUT_FRXGBPJPY_10_16_APR_07_5H5_6	2007-04-16 06:00:00	\N	\N
200519	2007-04-16 01:43:00	200339	frxEURUSD	10	5	10	2007-04-16 21:20:00	2007-04-16 21:30:00	2007-04-16 21:30:00	f	t	t	higher_lower_bet	PUT	\N	PUT_FRXEURUSD_10_16_APR_07_21H2_21H3	2007-04-16 21:30:00	\N	\N
202539	2009-09-29 05:53:00	200639	frxEURUSD	15.86	5	0	2009-09-29 05:53:52	2009-09-29 05:55:00	2009-09-29 05:55:00	f	t	t	higher_lower_bet	CALL	type=bull currency=GBP stake=5 profit=10.86 underlying=frxEURUSD duration=300 purchase_time=1254203632 start_time=1254203400 bull_bear_boundary_spot=1.4637 is_sold=0 sold_price=0 sold_time=0	CALL_FRXEURUSD_15.86_1254203632_1254203700_14637_0	2009-09-29 05:55:00	\N	\N
202599	2009-09-30 10:20:00	200639	frxAUDJPY	10	5.21	0	2009-09-30 10:20:08	2009-09-30 10:20:38	2009-09-30 10:20:38	f	t	t	higher_lower_bet	CALL	theo=5 trade=5.21 recalc=5.21 win=10 (0.5,buy) delta=0.01 vega=0 theta=0 gamma=0 intradaytime= theo=5 spot_time=1254306008 	CALL_FRXAUDJPY_10_30_SEP_09_S30_10H2008	2009-09-30 10:20:38	\N	\N
202679	2009-07-31 15:21:00	200699	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
202699	2009-10-07 04:00:00	200639	frxAUDJPY	10	6.13	10	2009-10-07 04:00:43	2009-10-07 04:05:43	2009-10-07 04:05:43	f	t	t	higher_lower_bet	CALL	theo=5.63 trade=6.13 recalc=6.13 win=10 [MarkupEngine::Hedge] S=78.96 r=0.00568 q=0.05213 t=9.51293759512938e-06 H=78.96 L=0 iv=0.1383 ATTRAC=0 (0.513404517767627,0.613404517767627,0.563404517767627,buy,FM=0) delta=93.5255346357448 vega=3.28180629702132e-05 theta=0.717706140009266 gamma=12.8814502847153 intradaytime= theo=5.63 spot_time=1254888043 	CALL_FRXAUDJPY_10_1254888043_1254888343_S0P_0	2009-10-07 04:05:43	\N	\N
203159	2009-11-09 02:22:00	200639	frxAUDJPY	60	32.46	60	2009-11-09 03:00:00	2009-11-09 04:00:00	2009-11-09 04:00:00	f	t	t	higher_lower_bet	CALL	\N	CALL_FRXAUDJPY_60_9_NOV_09_3_4	2009-11-09 04:00:00	\N	\N
200859	2009-10-16 08:27:00	200379	GDAXI	2	1.16	0	2009-10-16 00:00:00	2009-10-23 15:30:00	2009-10-23 23:59:59	t	t	t	higher_lower_bet	CALL	theo=1.03 trade=1.16 recalc=1.15 win=2 [MarkupEngine::Hedge] S=5868.71 r=0.01326 q=0.0003 t=0.0209521182141045 H=5869 L=0 iv=0.397692502162829 ATTRAC=0 (0.451562921501891,0.577114446506774,0.514338684004333,buy,FM=0) delta=0.138523398941272 vega=-0.000260287200372574 theta=0.00124551806854694 gamma=-0.000783836012067541 intradaytime= theo=1.03 spot_time=1255681654 	CALL_GDAXI_2_16_OCT_09_23_OCT_09_5869_0	2009-10-23 23:59:59	\N	\N
200899	2009-10-20 08:46:00	200379	frxEURUSD	10	7.26	0	2009-10-20 00:00:00	2009-10-21 00:00:00	2009-10-21 23:59:59	f	t	t	legacy_bet	DOUBLEONETOUCH	theo=5.97 trade=7.26 recalc=7.24 win=10 [MarkupEngine::Hedge] S=0.9126 r=0.0113 q=0.01326 t=0.00447761288685946 H=0.9163 L=0.9107 iv=0.191 (0.470343699687832,0.724264579356303,0.597304139522068,buy,FM=0) delta=-0.153374253450337 vega=0.0368378823608042 theta=-1.12652750894949 gamma=2.25702621452758 theo=5.97 spot_time=1256028394 	DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107	2009-10-21 23:59:59	\N	\N
200919	2009-10-23 05:42:00	200379	frxUSDCAD	2	1.04	0	2009-10-23 05:42:01	2009-10-23 05:42:31	2009-10-23 05:42:31	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1256276521 	CALL_FRXUSDCAD_2_23_OCT_09_S30_05H4201	2009-10-23 05:42:31	\N	\N
200959	2009-10-23 05:43:00	200379	frxUSDCAD	15	7.8	0	2009-10-23 05:43:16	2009-10-23 05:43:46	2009-10-23 05:43:46	f	t	t	higher_lower_bet	CALL	theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256276598 	CALL_FRXUSDCAD_15_23_OCT_09_S30_05H4316	2009-10-23 05:43:46	\N	\N
201019	2009-10-23 05:47:00	200379	frxUSDCAD	15	7.8	0	2009-10-23 05:47:05	2009-10-23 05:47:35	2009-10-23 05:47:35	f	t	t	higher_lower_bet	CALL	theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256276825 	CALL_FRXUSDCAD_15_23_OCT_09_S30_05H4705	2009-10-23 05:47:35	\N	\N
201039	2009-10-23 05:50:00	200379	frxAUDJPY	15	7.8	15	2009-10-23 05:50:48	2009-10-23 05:51:18	2009-10-23 05:51:18	f	t	t	higher_lower_bet	CALL	theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256277048 	CALL_FRXAUDJPY_15_23_OCT_09_S30_05H5048	2009-10-23 05:51:18	\N	\N
201079	2009-10-23 05:56:00	200379	frxAUDJPY	15	7.8	0	2009-10-23 05:56:48	2009-10-23 05:57:18	2009-10-23 05:57:18	f	t	t	higher_lower_bet	CALL	theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256277409 	CALL_FRXAUDJPY_15_23_OCT_09_S30_05H5648	2009-10-23 05:57:18	\N	\N
202719	2009-07-31 17:21:00	200699	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
202739	2009-07-31 17:21:00	200679	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
202759	2009-11-03 07:14:00	200639	frxAUDJPY	2	1.04	0	2009-11-03 07:14:47	2009-11-03 07:15:17	2009-11-03 07:15:17	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257232487 	CALL_FRXAUDJPY_2_3_NOV_09_S30_07H1447	2009-11-03 07:15:17	\N	\N
202779	2009-11-03 07:15:00	200639	frxAUDJPY	20	10.8	0	2009-11-03 08:00:00	2009-11-03 09:00:00	2009-11-03 09:00:00	f	t	t	higher_lower_bet	CALL	\N	CALL_FRXAUDJPY_20_3_NOV_09_8_9	2009-11-03 09:00:00	\N	\N
202399	2009-07-31 08:21:00	200579	frxXAUUSD	10000	3140	0	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
202519	2009-07-31 08:21:00	200699	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
200539	2009-10-16 08:27:00	200319	GDAXI	2	1.16	0	2009-10-16 00:00:00	2009-10-23 15:30:00	2009-10-23 23:59:59	t	t	t	higher_lower_bet	CALL	theo=1.03 trade=1.16 recalc=1.15 win=2 [MarkupEngine::Hedge] S=5868.71 r=0.01326 q=0.0003 t=0.0209521182141045 H=5869 L=0 iv=0.397692502162829 ATTRAC=0 (0.451562921501891,0.577114446506774,0.514338684004333,buy,FM=0) delta=0.138523398941272 vega=-0.000260287200372574 theta=0.00124551806854694 gamma=-0.000783836012067541 intradaytime= theo=1.03 spot_time=1255681654 	CALL_GDAXI_2_16_OCT_09_23_OCT_09_5869_0	2009-10-23 23:59:59	\N	\N
200559	2009-10-20 08:46:00	200319	frxEURUSD	10	7.26	0	2009-10-20 00:00:00	2009-10-21 00:00:00	2009-10-21 23:59:59	f	t	t	legacy_bet	DOUBLEONETOUCH	theo=5.97 trade=7.26 recalc=7.24 win=10 [MarkupEngine::Hedge] S=0.9126 r=0.0113 q=0.01326 t=0.00447761288685946 H=0.9163 L=0.9107 iv=0.191 (0.470343699687832,0.724264579356303,0.597304139522068,buy,FM=0) delta=-0.153374253450337 vega=0.0368378823608042 theta=-1.12652750894949 gamma=2.25702621452758 theo=5.97 spot_time=1256028394 	DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107	2009-10-21 23:59:59	\N	\N
200619	2009-10-23 05:42:00	200319	frxUSDCAD	2	1.04	0	2009-10-23 05:42:01	2009-10-23 05:42:31	2009-10-23 05:42:31	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1256276521 	CALL_FRXUSDCAD_2_23_OCT_09_S30_05H4201	2009-10-23 05:42:31	\N	\N
200679	2009-10-23 05:43:00	200319	frxUSDCAD	15	7.8	0	2009-10-23 05:43:16	2009-10-23 05:43:46	2009-10-23 05:43:46	f	t	t	higher_lower_bet	CALL	theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256276598 	CALL_FRXUSDCAD_15_23_OCT_09_S30_05H4316	2009-10-23 05:43:46	\N	\N
200699	2009-10-23 05:47:00	200319	frxUSDCAD	15	7.8	0	2009-10-23 05:47:05	2009-10-23 05:47:35	2009-10-23 05:47:35	f	t	t	higher_lower_bet	CALL	theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256276825 	CALL_FRXUSDCAD_15_23_OCT_09_S30_05H4705	2009-10-23 05:47:35	\N	\N
200719	2009-10-23 05:50:00	200319	frxAUDJPY	15	7.8	15	2009-10-23 05:50:48	2009-10-23 05:51:18	2009-10-23 05:51:18	f	t	t	higher_lower_bet	CALL	theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256277048 	CALL_FRXAUDJPY_15_23_OCT_09_S30_05H5048	2009-10-23 05:51:18	\N	\N
200759	2009-10-23 05:56:00	200319	frxAUDJPY	15	7.8	0	2009-10-23 05:56:48	2009-10-23 05:57:18	2009-10-23 05:57:18	f	t	t	higher_lower_bet	CALL	theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256277409 	CALL_FRXAUDJPY_15_23_OCT_09_S30_05H5648	2009-10-23 05:57:18	\N	\N
204699	2009-05-08 03:08:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204739	2009-05-08 03:42:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
202579	2009-07-31 11:21:00	200699	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
200979	2009-08-14 07:19:00	200399	frxGBPJPY	30	15.04	0	2009-08-14 07:19:52	2009-08-14 07:20:22	2009-08-14 07:20:22	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 intradaytime= theo=1	CALL_FRXGBPJPY_30_14_AUG_09_S30_07H1952	2009-08-14 07:20:22	\N	\N
202639	2009-07-31 13:21:00	200699	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
203679	2009-11-11 02:34:00	200639	frxAUDJPY	2	1.04	2	2009-11-11 02:34:42	2009-11-11 02:35:12	2009-11-11 02:35:12	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257906882 	CALL_FRXAUDJPY_2_11_NOV_09_S30_02H3442	2009-11-11 02:35:12	\N	\N
203719	2009-11-11 02:39:00	200639	frxAUDJPY	90	46.8	0	2009-11-11 02:39:21	2009-11-11 02:39:51	2009-11-11 02:39:51	f	t	t	higher_lower_bet	CALL	theo=45 trade=46.8 recalc=46.8 win=90 (0.5,buy) delta=0.09 vega=0 theta=0 gamma=0 theo=45 spot_time=1257907161 	CALL_FRXAUDJPY_90_11_NOV_09_S30_02H3921	2009-11-11 02:39:51	\N	\N
202499	2009-07-31 08:21:00	200679	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
202559	2009-07-31 11:21:00	200679	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
202619	2009-07-31 13:21:00	200679	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
202659	2009-07-31 15:21:00	200679	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
203699	2009-11-11 02:39:00	200639	frxAUDJPY	2	1.04	2	2009-11-11 02:39:06	2009-11-11 02:39:36	2009-11-11 02:39:36	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257907146 	CALL_FRXAUDJPY_2_11_NOV_09_S30_02H3906	2009-11-11 02:39:36	\N	\N
203739	2009-11-11 07:50:00	200639	frxAUDJPY	2	1.04	0	2009-11-11 07:50:22	2009-11-11 07:50:52	2009-11-11 07:50:52	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257925822 	CALL_FRXAUDJPY_2_11_NOV_09_S30_07H5022	2009-11-11 07:50:52	\N	\N
202839	2009-11-03 07:17:00	200639	frxAUDJPY	70	38.47	0	2009-11-03 07:17:53	2009-11-03 07:22:53	2009-11-03 07:22:53	f	t	t	higher_lower_bet	CALL	theo=34.97 trade=38.47 recalc=38.47 win=70 [MarkupEngine::Hedge] S=80.98 r=0.00568 q=0.05213 t=9.51293759512938e-06 H=80.98 L=0 iv=0.236999968651127 (0.449613012380696,0.549613012380696,0.499613012380696,buy,FM=0) delta=382.034219859719 vega=6.67451703122776e-05 theta=3.90119173209922 gamma=26.9962564778226 theo=34.97 spot_time=1257232673 	CALL_FRXAUDJPY_70_1257232673_1257232973_S0P_0	2009-11-03 07:22:53	\N	\N
202939	2009-11-04 10:41:00	200639	frxAUDJPY	2	1.04	0	2009-11-04 10:41:22	2009-11-04 10:41:52	2009-11-04 10:41:52	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257331282 	CALL_FRXAUDJPY_2_4_NOV_09_S30_10H4122	2009-11-04 10:41:52	\N	\N
203019	2009-11-05 03:33:00	200639	frxAUDJPY	2	1.08	0	2009-11-05 04:00:00	2009-11-05 05:00:00	2009-11-05 05:00:00	f	t	t	higher_lower_bet	CALL	\N	CALL_FRXAUDJPY_2_5_NOV_09_4_5	2009-11-05 05:00:00	\N	\N
203059	2009-11-05 05:46:00	200639	frxAUDJPY	50	23.66	0	2009-11-05 05:46:12	2009-11-05 05:51:12	2009-11-05 05:51:12	f	t	t	higher_lower_bet	CALL	theo=21.18 trade=23.66 recalc=23.68 win=50 [MarkupEngine::Hedge] S=82.05 r=0.00568 q=0.05213 t=9.51293759512938e-06 H=82.06 L=0 iv=0.205999978497277 (0.373548878168691,0.473548878168691,0.423548878168691,buy,FM=0) delta=308.163981194486 vega=0.0376297522575727 theta=-537.946399685496 gamma=955.290700801182 theo=21.18 spot_time=1257399972 	CALL_FRXAUDJPY_50_1257399972_1257400272_S1P_0	2009-11-05 05:51:12	\N	\N
204799	2009-05-08 03:47:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
203099	2009-11-05 06:33:00	200639	frxAUDJPY	20	9.77	20	2009-11-05 00:00:00	2009-11-12 23:59:59	2009-11-12 23:59:59	t	t	t	touch_bet	ONETOUCH	theo=8.57 trade=9.77 recalc=9.77 win=20 [MarkupEngine::Hedge] S=82.07 r=0.00568 q=0.05213 t=0.021169964485033 H=83.32 L=0 iv=0.138116787798239 (0.368671613549441,0.488671613549441,0.428671613549441,buy,FM=0) delta=5.97661826085479 vega=0.09295611798753 theta=-0.558884310351264 gamma=2.45204323440237 theo=8.57 spot_time=1257402784 	ONETOUCH_FRXAUDJPY_20_5_NOV_09_12_NOV_09_833200_0	2009-11-12 23:59:59	\N	\N
203119	2009-11-05 06:34:00	200639	frxAUDJPY	20	9.77	20	2009-11-05 00:00:00	2009-11-12 23:59:59	2009-11-12 23:59:59	t	t	t	touch_bet	ONETOUCH	theo=8.57 trade=9.77 recalc=9.77 win=20 [MarkupEngine::Hedge] S=82.07 r=0.00568 q=0.05213 t=0.021169964485033 H=83.32 L=0 iv=0.138116787798239 (0.368671613549441,0.488671613549441,0.428671613549441,buy,FM=0) delta=5.97661826085479 vega=0.09295611798753 theta=-0.558884310351264 gamma=2.45204323440237 theo=8.57 spot_time=1257402844 	ONETOUCH_FRXAUDJPY_20_5_NOV_09_12_NOV_09_833200_0	2009-11-12 23:59:59	\N	\N
203199	2009-11-09 06:50:00	200639	frxAUDJPY	20	10.4	20	2009-11-09 06:50:38	2009-11-09 06:51:08	2009-11-09 06:51:08	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257749438 	CALL_FRXAUDJPY_20_9_NOV_09_S30_06H5038	2009-11-09 06:51:08	\N	\N
203259	2009-11-09 06:52:00	200639	frxAUDJPY	20	10.4	0	2009-11-09 06:52:55	2009-11-09 06:53:25	2009-11-09 06:53:25	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257749575 	CALL_FRXAUDJPY_20_9_NOV_09_S30_06H5255	2009-11-09 06:53:25	\N	\N
205359	2009-05-08 06:28:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
203319	2009-11-09 09:59:00	200639	frxAUDJPY	90	46.8	90	2009-11-09 09:59:51	2009-11-09 10:00:21	2009-11-09 10:00:21	f	t	t	higher_lower_bet	CALL	theo=45 trade=46.8 recalc=46.8 win=90 (0.5,buy) delta=0.09 vega=0 theta=0 gamma=0 theo=45 spot_time=1257760791 	CALL_FRXAUDJPY_90_9_NOV_09_S30_09H5951	2009-11-09 10:00:21	\N	\N
203359	2009-11-09 10:00:00	200639	frxAUDJPY	90	46.8	0	2009-11-09 10:00:11	2009-11-09 10:00:41	2009-11-09 10:00:41	f	t	t	higher_lower_bet	CALL	theo=45 trade=46.8 recalc=46.8 win=90 (0.5,buy) delta=0.09 vega=0 theta=0 gamma=0 theo=45 spot_time=1257760811 	CALL_FRXAUDJPY_90_9_NOV_09_S30_10H0011	2009-11-09 10:00:41	\N	\N
203379	2009-11-09 10:00:00	200639	frxAUDJPY	90	46.8	0	2009-11-09 10:00:38	2009-11-09 10:01:08	2009-11-09 10:01:08	f	t	t	higher_lower_bet	CALL	theo=45 trade=46.8 recalc=46.8 win=90 (0.5,buy) delta=0.09 vega=0 theta=0 gamma=0 theo=45 spot_time=1257760838 	CALL_FRXAUDJPY_90_9_NOV_09_S30_10H0038	2009-11-09 10:01:08	\N	\N
203419	2009-11-10 08:55:00	200639	frxAUDJPY	20	10.4	0	2009-11-10 08:55:39	2009-11-10 08:56:09	2009-11-10 08:56:09	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257843339 	CALL_FRXAUDJPY_20_10_NOV_09_S30_08H5539	2009-11-10 08:56:09	\N	\N
203439	2009-11-10 08:56:00	200639	frxAUDJPY	20	10.4	0	2009-11-10 08:56:51	2009-11-10 08:57:21	2009-11-10 08:57:21	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257843411 	CALL_FRXAUDJPY_20_10_NOV_09_S30_08H5651	2009-11-10 08:57:21	\N	\N
203459	2009-11-10 09:20:00	200639	frxAUDJPY	20	10.4	0	2009-11-10 09:20:54	2009-11-10 09:21:24	2009-11-10 09:21:24	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257844854 	CALL_FRXAUDJPY_20_10_NOV_09_S30_09H2054	2009-11-10 09:21:24	\N	\N
203479	2009-11-10 09:39:00	200639	frxAUDJPY	20	10.4	20	2009-11-10 09:39:51	2009-11-10 09:40:21	2009-11-10 09:40:21	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257845992 	CALL_FRXAUDJPY_20_10_NOV_09_S30_09H3951	2009-11-10 09:40:21	\N	\N
203499	2009-11-10 09:48:00	200639	frxAUDJPY	20	10.4	0	2009-11-10 09:48:44	2009-11-10 09:49:14	2009-11-10 09:49:14	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257846525 	CALL_FRXAUDJPY_20_10_NOV_09_S30_09H4844	2009-11-10 09:49:14	\N	\N
203519	2009-11-10 09:50:00	200639	frxAUDJPY	20	10.4	0	2009-11-10 09:50:27	2009-11-10 09:50:57	2009-11-10 09:50:57	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257846627 	CALL_FRXAUDJPY_20_10_NOV_09_S30_09H5027	2009-11-10 09:50:57	\N	\N
203539	2009-11-10 09:55:00	200639	frxAUDJPY	20	10.4	20	2009-11-10 09:55:40	2009-11-10 09:56:10	2009-11-10 09:56:10	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257846940 	CALL_FRXAUDJPY_20_10_NOV_09_S30_09H5540	2009-11-10 09:56:10	\N	\N
203599	2009-11-10 09:59:00	200639	frxAUDJPY	20	10.4	0	2009-11-10 09:59:47	2009-11-10 10:00:17	2009-11-10 10:00:17	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257847187 	CALL_FRXAUDJPY_20_10_NOV_09_S30_09H5947	2009-11-10 10:00:17	\N	\N
203659	2009-11-11 02:00:00	200639	frxAUDJPY	2	1.04	2	2009-11-11 02:00:15	2009-11-11 02:00:45	2009-11-11 02:00:45	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257904815 	CALL_FRXAUDJPY_2_11_NOV_09_S30_02H0015	2009-11-11 02:00:45	\N	\N
203639	2009-11-11 01:56:00	200639	frxAUDJPY	2	1.04	2	2009-11-11 01:56:43	2009-11-11 01:57:13	2009-11-11 01:57:13	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257904603 	CALL_FRXAUDJPY_2_11_NOV_09_S30_01H5643	2009-11-11 01:57:13	\N	\N
203619	2009-11-10 09:59:00	200639	frxAUDJPY	20	10.4	0	2009-11-10 09:59:57	2009-11-10 10:00:27	2009-11-10 10:00:27	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257847197 	CALL_FRXAUDJPY_20_10_NOV_09_S30_09H5957	2009-11-10 10:00:27	\N	\N
203579	2009-11-10 09:59:00	200639	frxAUDJPY	20	10.4	0	2009-11-10 09:59:35	2009-11-10 10:00:05	2009-11-10 10:00:05	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257847176 	CALL_FRXAUDJPY_20_10_NOV_09_S30_09H5935	2009-11-10 10:00:05	\N	\N
203559	2009-11-10 09:59:00	200639	frxAUDJPY	20	10.4	20	2009-11-10 09:59:02	2009-11-10 09:59:32	2009-11-10 09:59:32	f	t	t	higher_lower_bet	CALL	theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257847143 	CALL_FRXAUDJPY_20_10_NOV_09_S30_09H5902	2009-11-10 09:59:32	\N	\N
202799	2009-07-31 19:21:00	200699	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
202859	2009-07-31 21:21:00	200699	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
204839	2009-05-08 03:47:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
202899	2009-07-31 23:21:00	200699	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
203239	2009-11-09 09:59:00	200799	frxAUDJPY	90	46.8	90	2009-11-09 09:59:51	2009-11-09 10:00:21	2009-11-09 10:00:21	f	t	t	higher_lower_bet	CALL	theo=45 trade=46.8 recalc=46.8 win=90 (0.5,buy) delta=0.09 vega=0 theta=0 gamma=0 theo=45 spot_time=1257760791 	CALL_FRXAUDJPY_90_9_NOV_09_S30_09H5951	2009-11-09 10:00:21	\N	\N
202819	2009-07-31 19:21:00	200679	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
202959	2009-07-31 23:49:00	200699	frxUSDJPY	20	10	19	2009-07-31 23:49:00	2009-07-31 23:49:05	2009-07-31 23:49:05	f	t	t	run_bet	RUNBET_DOUBLEDOWN	frxUSDJPY forecast=DOWN Run=114.136,114.139,114.101,114.104,114.138,114.125,	RUNBET_DOUBLEDOWN_GBP200_frxUSDJPY_5	2009-07-31 23:49:05	\N	\N
202879	2009-07-31 21:21:00	200679	frxXAUUSD	10000	3140	0	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
202919	2009-07-31 23:21:00	200679	frxXAUUSD	10000	3140	10000	2009-07-31 08:21:24	2009-07-31 08:26:24	2009-07-31 08:26:24	f	t	t	higher_lower_bet	CALL	theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49	CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0	2009-07-31 08:26:24	\N	\N
203759	2009-11-12 04:08:00	200639	frxAUDJPY	2	1.04	0	2009-11-12 04:08:49	2009-11-12 04:09:19	2009-11-12 04:09:19	f	t	t	higher_lower_bet	CALL	theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257998929 	CALL_FRXAUDJPY_2_12_NOV_09_S30_04H0849	2009-11-12 04:09:19	\N	\N
205279	2009-05-08 06:26:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
203959	2009-05-05 02:18:00	1202	frxXAUUSD	50	18.1	8.32	2009-05-05 00:00:00	2009-05-12 23:59:59	2009-05-12 23:59:59	t	t	t	range_bet	EXPIRYRANGE	theo=12.5 trade=18.1 recalc=18.1 win=50 [MarkupEngine::Hedge] S=904.65 r=0.0104 q=0.027833 t=0.0216538876204972 H=912.19 L=897.12 iv=0.211166536239101 ATTRAC=-2 (0.140053510461251,0.360053510461251,0.250053510461251,buy,FM=) delta=0.0887467305655004 vega=-0.103117721157029 theta=0.653065622264854 gamma=-1.06794076594247 intradaytime= theo=12.5 	EXPIRYRANGE_FRXXAUUSD_50_5_MAY_09_12_MAY_09_9121900_8971200	2009-05-12 23:59:59	\N	\N
204099	2009-05-07 09:55:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204139	2009-05-07 09:55:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204159	2009-05-07 09:56:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204199	2009-05-07 09:58:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204219	2009-05-08 02:16:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204259	2009-05-08 02:20:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204299	2009-05-08 02:22:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204319	2009-05-08 02:22:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204359	2009-05-08 02:49:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204399	2009-05-08 02:50:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204439	2009-05-08 02:52:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204479	2009-05-08 02:59:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204519	2009-05-08 03:03:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204559	2009-05-08 03:06:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204619	2009-05-08 03:07:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204659	2009-05-08 03:08:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204879	2009-05-08 03:55:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204919	2009-05-08 04:15:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204959	2009-05-08 04:18:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
204999	2009-05-08 04:19:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
205039	2009-05-08 04:20:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
205079	2009-05-08 04:23:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
205119	2009-05-08 04:23:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
205159	2009-05-08 06:17:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
205199	2009-05-08 06:20:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
205239	2009-05-08 06:20:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
205319	2009-05-08 06:27:00	1202	frxUSDJPY	50	30.82	8.32	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
205379	2009-05-08 06:27:00	201119	frxUSDJPY	30	20	10	2009-05-05 00:00:00	2009-05-06 23:59:59	2009-05-06 23:59:59	t	t	t	range_bet	EXPIRYRANGE	\N	EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400	2009-05-06 23:59:59	\N	\N
\.


--
-- Data for Name: higher_lower_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

COPY higher_lower_bet (financial_market_bet_id, relative_barrier, absolute_barrier, prediction) FROM stdin;
200139	S0P	\N	\N
200379	S0P	\N	\N
200539	\N	5869	\N
200519	S0P	\N	\N
200579	S0P	\N	\N
200619	S0P	\N	\N
200659	S0P	\N	\N
200679	S0P	\N	\N
200699	S0P	\N	\N
200719	S0P	\N	\N
200759	S0P	\N	\N
200859	\N	5869	\N
200919	S0P	\N	\N
200959	S0P	\N	\N
200979	S0P	\N	\N
201019	S0P	\N	\N
201039	S0P	\N	\N
201079	S0P	\N	\N
202359	\N	936.74	\N
202399	\N	936.74	\N
202499	\N	936.74	\N
202519	\N	936.74	\N
202559	\N	936.74	\N
202579	\N	936.74	\N
202599	S0P	\N	\N
202619	\N	936.74	\N
202639	\N	936.74	\N
202659	\N	936.74	\N
202679	\N	936.74	\N
202699	S0P	\N	\N
202719	\N	936.74	\N
202739	\N	936.74	\N
202759	S0P	\N	\N
202779	S0P	\N	\N
202799	\N	936.74	\N
202819	\N	936.74	\N
202839	S0P	\N	\N
202859	\N	936.74	\N
202879	\N	936.74	\N
202899	\N	936.74	\N
202919	\N	936.74	\N
202939	S0P	\N	\N
203019	S0P	\N	\N
203059	S1P	\N	\N
203159	S0P	\N	\N
203199	S0P	\N	\N
203239	S0P	\N	\N
203259	S0P	\N	\N
203319	S0P	\N	\N
203359	S0P	\N	\N
203379	S0P	\N	\N
203419	S0P	\N	\N
203439	S0P	\N	\N
203459	S0P	\N	\N
203479	S0P	\N	\N
203499	S0P	\N	\N
203519	S0P	\N	\N
203539	S0P	\N	\N
203559	S0P	\N	\N
203579	S0P	\N	\N
203599	S0P	\N	\N
203619	S0P	\N	\N
203639	S0P	\N	\N
203659	S0P	\N	\N
203679	S0P	\N	\N
203699	S0P	\N	\N
203719	S0P	\N	\N
203739	S0P	\N	\N
203759	S0P	\N	\N
\.


--
-- Data for Name: legacy_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

COPY legacy_bet (financial_market_bet_id, absolute_lower_barrier, absolute_higher_barrier, intraday_ifunless, intraday_starthour, intraday_leg1, intraday_midhour, intraday_leg2, intraday_endhour, short_code) FROM stdin;
200439	0.9107	0.9163	\N	\N	\N	\N	\N	\N	DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107
200459	0.9107	0.9163	\N	\N	\N	\N	\N	\N	DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107
200559	0.9107	0.9163	\N	\N	\N	\N	\N	\N	DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107
200899	0.9107	0.9163	\N	\N	\N	\N	\N	\N	DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107
\.


--
-- Data for Name: range_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

--
-- Data for Name: range_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

COPY range_bet (financial_market_bet_id, relative_lower_barrier, absolute_lower_barrier, relative_higher_barrier, absolute_higher_barrier, prediction) FROM stdin;
203959	\N	897.12	\N	912.19	\N
204099	\N	98.14	\N	99.5	\N
204139	\N	98.14	\N	99.5	\N
204159	\N	98.14	\N	99.5	\N
204199	\N	98.14	\N	99.5	\N
204219	\N	98.14	\N	99.5	\N
204259	\N	98.14	\N	99.5	\N
204299	\N	98.14	\N	99.5	\N
204319	\N	98.14	\N	99.5	\N
204359	\N	98.14	\N	99.5	\N
204399	\N	98.14	\N	99.5	\N
204439	\N	98.14	\N	99.5	\N
204479	\N	98.14	\N	99.5	\N
204519	\N	98.14	\N	99.5	\N
204559	\N	98.14	\N	99.5	\N
204619	\N	98.14	\N	99.5	\N
204659	\N	98.14	\N	99.5	\N
204699	\N	98.14	\N	99.5	\N
204739	\N	98.14	\N	99.5	\N
204799	\N	98.14	\N	99.5	\N
204839	\N	98.14	\N	99.5	\N
204879	\N	98.14	\N	99.5	\N
204919	\N	98.14	\N	99.5	\N
204959	\N	98.14	\N	99.5	\N
204999	\N	98.14	\N	99.5	\N
205039	\N	98.14	\N	99.5	\N
205079	\N	98.14	\N	99.5	\N
205119	\N	98.14	\N	99.5	\N
205159	\N	98.14	\N	99.5	\N
205199	\N	98.14	\N	99.5	\N
205239	\N	98.14	\N	99.5	\N
205279	\N	98.14	\N	99.5	\N
205319	\N	98.14	\N	99.5	\N
205359	\N	98.14	\N	99.5	\N
\.


--
-- Data for Name: run_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

COPY run_bet (financial_market_bet_id, number_of_ticks, last_digit, prediction) FROM stdin;
200499	5	\N	up
200639	5	\N	down
200799	5	\N	down
200819	5	\N	down
200879	5	\N	up
200999	5	\N	down
201059	5	\N	down
201119	5	\N	up
201139	5	\N	up
201199	5	\N	up
201259	5	\N	up
201299	5	\N	up
201419	5	\N	down
201459	5	\N	up
201519	5	\N	up
201599	5	\N	up
201619	5	\N	up
201659	5	\N	down
201839	5	\N	up
201859	5	\N	up
201879	5	\N	up
201899	5	\N	up
201919	5	\N	up
201939	5	\N	up
201979	5	\N	down
201999	5	\N	down
202019	5	\N	down
202099	5	\N	up
202119	5	\N	up
202179	5	\N	up
202199	5	\N	up
202319	5	\N	down
202959	5	\N	down
202979	5	\N	down
\.


--
-- Data for Name: touch_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

COPY touch_bet (financial_market_bet_id, relative_barrier, absolute_barrier, prediction) FROM stdin;
203099	\N	83.32	\N
203119	\N	83.32	\N
\.

SET search_path = betonmarkets, pg_catalog;


--
-- Data for Name: client_authentication_document; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

COPY client_authentication_document (id, document_type, document_format, document_path, client_loginid, authentication_method_code, checksum) FROM stdin;
1838	passport	txt	/home/git/regentmarkets/bom/t/data/db/clientIDscans/CR/CR0009.passport.1233801953.txt	CR0009	ID_DOCUMENT	1234456Abcdert\N
1878	address	txt	/home/git/regentmarkets/bom/t/data/db/clientIDscans/CR/CR0009.address.1233817301.txt	CR0009	ID_DOCUMENT	1234456Abcdert\N
1858	certified_passport	png	/home/git/regentmarkets/bom/t/data/db/clientIDscans/CR/CR0009.certified_passport.png	CR0009	ID_DOCUMENT	1234456Abcdert\N
\.


--
-- Data for Name: client_authentication_method; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

COPY client_authentication_method (id, client_loginid, authentication_method_code, last_modified_date, status, description) FROM stdin;
218	MLT0012	PHONE_NUMBER	2016-04-12 12:57:59	pass	60122373211
238	MLT0012	ADDRESS	2016-04-12 12:57:59	pending	address   tiwn 12341 Indonesia
278	MLT0013	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234567
298	MLT0013	ADDRESS	2016-04-12 12:57:59	pending	test test   test 12345 Australia
338	MLT0014	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234549
358	MLT0014	ADDRESS	2016-04-12 12:57:59	pending	test test   test 11111 Australia
398	MLT0015	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234549
418	MLT0015	ADDRESS	2016-04-12 12:57:59	pending	test test   test 11111 Australia
458	MLT0016	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234549
478	MLT0016	ADDRESS	2016-04-12 12:57:59	pending	test test   test 11111 Australia
498	MX0012	PHONE_NUMBER	2016-04-12 12:57:59	pass	60122373211
518	MX0012	ADDRESS	2016-04-12 12:57:59	pending	address   tiwn 12341 Indonesia
558	MX0013	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234567
578	MX0013	ADDRESS	2016-04-12 12:57:59	pending	test test   test 12345 Australia
618	MX0014	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234549
638	MX0014	ADDRESS	2016-04-12 12:57:59	pending	test test   test 11111 Australia
678	MX0015	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234549
698	MX0015	ADDRESS	2016-04-12 12:57:59	pending	test test   test 11111 Australia
738	MX0016	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234549
758	MX0016	ADDRESS	2016-04-12 12:57:59	pending	test test   test 11111 Australia
778	CR0002	ADDRESS	2016-04-12 12:57:59	pass	test1 test2 te12st
798	CR0003	ADDRESS	2016-04-12 12:57:59	pass	test1 test2 te12st
818	CR0004	ADDRESS	2016-04-12 12:57:59	pass	test1 test2 te12st
838	CR0005	ADDRESS	2016-04-12 12:57:59	pass	test1 test2 te12st
858	CR0006	ADDRESS	2016-04-12 12:57:59	pass	test1 test2 te12st
878	CR0007	PHONE_NUMBER	2016-04-12 12:57:59	pass	8187876876
898	CR0007	ADDRESS	2016-04-12 12:57:59	pass	test1 test2 te12st
918	CR0007	ID_DOCUMENT	2016-04-12 12:57:59	pass	
938	CR0008	PHONE_NUMBER	2016-04-12 12:57:59	pass	8187876876
958	CR0008	ADDRESS	2016-04-12 12:57:59	pass	test1 test2 te12st
978	CR0009	PHONE_NUMBER	2016-04-12 12:57:59	pass	00869145685792
998	CR0009	ID_DOCUMENT	2016-04-12 12:57:59	pass	
1018	CR0010	PHONE_NUMBER	2016-04-12 12:57:59	pass	989125707281
1038	CR0011	PHONE_NUMBER	2016-04-12 12:57:59	pass	5689565695
1058	CR0012	PHONE_NUMBER	2016-04-12 12:57:59	pass	60122373211
1078	CR0012	ADDRESS	2016-04-12 12:57:59	pending	address   tiwn 12341 Indonesia
1118	CR0013	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234567
1138	CR0013	ADDRESS	2016-04-12 12:57:59	pending	test test   test 12345 Australia
1178	CR0014	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234549
1198	CR0014	ADDRESS	2016-04-12 12:57:59	pending	test test   test 11111 Australia
1238	CR0015	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234549
1258	CR0015	ADDRESS	2016-04-12 12:57:59	pending	test test   test 11111 Australia
1298	CR0016	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234549
1318	CR0016	ADDRESS	2016-04-12 12:57:59	pending	test test   test 11111 Australia
1338	CR0017	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234556
1358	CR0017	ADDRESS	2016-04-12 12:57:59	pass	test test   test 12345 Australia
1378	CR0017	ID_DOCUMENT	2016-04-12 12:57:59	pass	
1398	CR0020	PHONE_NUMBER	2016-04-12 12:57:59	pass	5689565695
1418	CR0021	PHONE_NUMBER	2016-04-12 12:57:59	pass	5689565695
1458	CR0026	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234549
1478	CR0026	ADDRESS	2016-04-12 12:57:59	pending	test test   test 11111 Australia
1518	CR0027	PHONE_NUMBER	2016-04-12 12:57:59	pass	611234549
1538	CR0027	ADDRESS	2016-04-12 12:57:59	pending	test test   test 11111 Australia
1578	CR0028	PHONE_NUMBER	2016-04-12 12:57:59	pass	6712345678
1598	CR0028	ADDRESS	2016-04-12 12:57:59	pending	Igloo 1 Polar street   Bearcity 11111 Antarctica
1638	CR0029	PHONE_NUMBER	2016-04-12 12:57:59	pass	6712345678
1658	CR0029	ADDRESS	2016-04-12 12:57:59	pending	Igloo 1 Polar street   Bearcity 11111 Antarctica
1698	CR0030	PHONE_NUMBER	2016-04-12 12:57:59	pass	6712345678
1718	CR0030	ADDRESS	2016-04-12 12:57:59	pending	Igloo 1 Polar street   Bearcity 11111 Antarctica
1738	CR0031	PHONE_NUMBER	2016-04-12 12:57:59	pass	00869145685792
1758	CR0031	ADDRESS	2016-04-12 12:57:59	pass	NING BO, CHINA
1778	CR0031	ID_DOCUMENT	2016-04-12 12:57:59	pass	
1898	CR0009	ADDRESS	2016-04-12 12:57:59	pass	NING BO, CHINA
2738	MLT0017	ID_DOCUMENT	2016-04-12 12:57:59	pass	
2678	MLT0017	ADDRESS	2016-04-12 12:57:59	pending	
\.


--
-- Data for Name: promo_code; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

COPY promo_code (code, start_date, expiry_date, status, promo_code_type, promo_code_config, description) FROM stdin;
BOM2009	\N	2019-01-10 00:00:00	t	FREE_BET	{"country":"ALL","currency":"ALL","amount":"20"}	Testing promocode
BOM-XY	\N	2015-01-30 00:00:00	t	GET_X_WHEN_DEPOSIT_Y	{"country":"ALL","currency":"USD","amount":"100","min_deposit":"100"}	deposit
0013F10	\N	2020-01-10 00:00:00	t	FREE_BET	{"country":"ALL","currency":"ALL","amount":"10"}	Subordinate affiliate testing promocode (username calum2, userid 13)
ABC123	\N	2019-01-10 00:00:00	t	FREE_BET	{"min_turnover":"100","country":"ALL","currency":"USD","amount":"10"}	Testing promocode
\.


--
-- Data for Name: client_promo_code; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

COPY client_promo_code (id, client_loginid, promotion_code, apply_date, status, mobile, checked_in_myaffiliates) FROM stdin;
258	MLT0013	BOM2009	\N	CLAIM	611234567	f
318	MLT0014	BOM2009	\N	CLAIM	611234549	f
378	MLT0015	BOM2009	\N	CLAIM	611234549	f
438	MLT0016	BOM2009	\N	CLAIM	611234549	f
538	MX0013	BOM2009	\N	CLAIM	611234567	f
598	MX0014	BOM2009	\N	CLAIM	611234549	f
658	MX0015	BOM2009	\N	CLAIM	611234549	f
718	MX0016	BOM2009	\N	CLAIM	611234549	f
1098	CR0013	BOM2009	\N	CLAIM	611234567	f
1158	CR0014	BOM2009	\N	CLAIM	611234549	f
1218	CR0015	BOM2009	\N	CLAIM	611234549	f
1278	CR0016	BOM2009	\N	CLAIM	611234549	f
1438	CR0026	BOM2009	\N	CLAIM	611234549	f
1498	CR0027	0013F10	\N	CLAIM	611234549	f
1558	CR0028	BOM2009	\N	CLAIM	6712345678	f
1618	CR0029	BOM-XY	\N	CLAIM	6712345678	f
1678	CR0030	BOM-XY	\N	CLAIM	6712345678	f
2118	CR0009	BOM-XY	\N	CLAIM	00869145685792	f
3458	CR0011	BOM2009	2010-05-12 06:40:11	NOT_CLAIM		f
3600	CR2002	ABC123	2014-01-01 06:40:11	CLAIM		f
\.


--
-- Data for Name: client_status; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

COPY client_status (id, client_loginid, status_code, staff_name, reason, last_modified_date) FROM stdin;
1798	CR0008	unwelcome	system	use for testing	2016-04-12 12:57:59
1818	CR0008	disabled	system	FOR TESTING	2016-04-12 12:57:59
\.


--
-- Data for Name: payment_agent; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

COPY payment_agent (client_loginid, payment_agent_name, url, email, phone, information, summary, commission_deposit, commission_withdrawal, is_authenticated, api_ip, currency_code, target_country, supported_banks) FROM stdin;
CR0020	Paypal	http://yahoo.com	jys@my.regentmarkets.com	987987987	paypal egold neteller and a lot more	iuhiuh	0.100000001	0.5	t	\N	USD		GTBank
\.


--
-- Data for Name: self_exclusion; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

COPY self_exclusion (client_loginid, max_balance, max_turnover, max_open_bets, exclude_until, session_duration_limit, last_modified_date, max_losses, max_7day_turnover, max_7day_losses, max_30day_turnover, max_30day_losses) FROM stdin;
CR0031	31000	2000	15	2014-11-25	25	2016-04-12 12:57:59	\N	\N	\N	\N	\N
CR0009	200000	1000	50	2009-09-06	20	2016-04-12 12:57:59	\N	\N	\N	\N	\N
\.


SET search_path = payment, pg_catalog;

--
-- Data for Name: payment; Type: TABLE DATA; Schema: payment; Owner: postgres
--

COPY payment (id, payment_time, amount, payment_gateway_code, payment_type_code, status, account_id, staff_loginid, remark) FROM stdin;
12003	2010-07-27 05:37:07	1000.0000	doughflow	external_cashier	OK	1203	test_staff	Sample!
200019	2011-01-01 08:00:00	150.0000	legacy_payment	compacted_statement	OK	200039	MX1001	Compacted statement prior to 01-Jan-11 08h00GMT; purchases=GBP100.00 sales=GBP50.00 deposits=GBP500.00 withdrawals=GBP200 purchases_intradaydoubles=GBP10 purchases_runbets=GBP80
200039	2011-03-09 06:22:00	2000.0000	moneybookers	ewallet	OK	200039	MX1001	Moneybookers deposit REF:MX100111271050920 ID:257054611 Email:ohoushyar@gmail.com Amount:GBP2000.00 Moneybookers Timestamp 9-Mar-11 05h44GMT
200059	2011-03-09 07:22:00	2000.0000	legacy_payment	ewallet	OK	200039	MX1001	sample remark 2
200069	2011-03-09 07:23:00	100.0000	legacy_payment	ewallet	OK	200039	MX1001	sample remark 3
200070	2011-03-09 07:24:00	100.0000	legacy_payment	ewallet	OK	200039	MX1001	sample remark 4
200079	2011-03-09 08:00:00	-100.0000	legacy_payment	ewallet	OK	200039	MX1001	Neteller withdrawal to account 451724851552 Transaction id 4058036 to neteller a/c 451724851552 (request GBP 100 / received GBP 100)
200159	2009-08-13 09:35:00	20.0000	free_gift	free_gift	OK	200099	CR5154	Free gift (claimed from mobile 611234567)
200219	2009-08-13 09:35:00	20.0000	free_gift	free_gift	OK	200199	MLT5154	Free gift (claimed from mobile 611234567)
200239	2008-07-24 08:15:00	5000.0000	legacy_payment	credit_debit_card	OK	200219	CR0031	Credit Card Deposit visa
200259	2010-05-18 09:11:00	-100.0000	datacash	bacs	OK	200219	CR0031	BACS withdrawal to bank account ::ecp::52616e646f6d495633363368676674791b651ae4a55c9cc38235c177ced55b71e55343376ac555f2 (USD100=GBP69.36) status=42
200279	2010-05-18 09:12:00	-100.0000	datacash	bacs	OK	200219	CR0031	BACS withdrawal to bank account ::ecp::52616e646f6d495633363368676674791b651ae4a55c9cc3e5e28a7713e7cc12ee3ba61384d27e4e (USD100=GBP69.36) status=44
200299	2010-05-18 09:14:00	-100.0000	datacash	bacs	OK	200219	CR0031	BACS withdrawal to bank account ::ecp::52616e646f6d495633363368676674791b651ae4a55c9cc3e5e28a7713e7cc12ee3ba61384d27e4e (USD100=GBP69.36) status=44
200319	2010-05-18 09:24:00	-100.0000	datacash	bacs	OK	200219	CR0031	BACS withdrawal to bank account ::ecp::52616e646f6d495633363368676674791b651ae4a55c9cc3e5e28a7713e7cc12ee3ba61384d27e4e (USD100=GBP69.36) status=44
200339	2010-05-19 09:24:00	-100.0000	datacash	bacs	OK	200219	CR0031	BACS withdrawal to bank account ::ecp::52616e646f6d495633363368676674791b651ae4a55c9cc3e5e28a7713e7cc12ee3ba61384d27e4e (USD100=GBP69.36) status=44
200379	2009-11-18 10:11:00	6180.0000	bank_wire	bank_money_transfer	OK	200259	geokkheng	Wire deposit from Sutrisno Suryoputro Received by RBSI 5880-58269864 on 18-Nov-09; Bank Ref#  46510567; Bank Name  HSBC Bank; Acct No  007-059066-081; Acct Name  Sutrisno Suryoputro
200439	2009-11-18 03:13:00	100.0000	free_gift	free_gift	OK	200259	CR0029	Free gift (claimed from mobile 611231242)
200419	2009-11-18 04:18:00	500.0000	datacash	credit_debit_card	OK	200279	CR0028	BLURB=datacash credit card deposit ORDERID=77516256288 (71516256288,) TIMESTAMP=18-Nov-09 04h18GMT
200459	2009-09-10 04:18:00	1000.0000	datacash	credit_debit_card	OK	200299	CR0016	BLURB=datacash credit card deposit ORDERID=77516256288 (77315256388,) TIMESTAMP=10-Sep-09 04h18GMT
200499	2009-11-18 04:18:00	20.0000	free_gift	free_gift	OK	200279	CR0028	Free gift (claimed from mobile 6712345678) (4900200063643402,) TIMESTAMP=18-Nov-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS 
200519	2009-09-10 04:18:00	20.0000	free_gift	free_gift	OK	200299	CR0016	Free gift (claimed from mobile 611234549) (4900200063643402,) TIMESTAMP=10-Sep-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS 
200539	2009-09-10 04:18:00	100.0000	datacash	credit_debit_card	OK	200319	CR0016	BLURB=datacash credit card deposit ORDERID=77516256288 (4900200063643402,) TIMESTAMP=10-Sep-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS
200559	2007-04-15 21:02:00	10.0000	legacy_payment	ewallet	OK	200339	CR0025	Egold deposit Batch 79320704 from egold ac 4312604 (0.014586 ounces of Gold at $685.60/ounce) Egold Ti$
200599	2005-09-21 06:14:00	600.0000	legacy_payment	ewallet	OK	200359	CR0021	Egold deposit Batch 49100734 from egold ac 2427854 (1.291156 ounces of Gold at $464.70/ounce) Egold Timestamp 1127283282
200579	2009-09-10 04:28:00	200.0000	envoy_transfer	bank_money_transfer	OK	200319	CR0016	Envoy deposit
200619	2007-04-16 01:53:00	5.0000	legacy_payment	ewallet	OK	200339	CR0025	Egold deposit Batch 79327577 from egold ac 4312604 (0.007308 ounces of Gold at $684.20/ounce) Egold Tim$
200639	2007-04-16 21:34:00	5.0000	legacy_payment	ewallet	OK	200339	CR0025	Egold deposit Batch 79375397 from egold ac 4312604 (0.007241 ounces of Gold at $690.50/ounce) Egold Tim$
200659	2009-09-10 04:18:00	100.0000	datacash	credit_debit_card	OK	200379	CR0016	BLURB=datacash credit card deposit ORDERID=77516256288 (4900200063643402,) TIMESTAMP=10-Sep-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS
200679	2009-09-10 04:28:00	200.0000	envoy_transfer	bank_money_transfer	OK	200379	CR0016	Envoy deposit
200699	2009-08-13 09:35:00	20.0000	free_gift	free_gift	OK	200399	CR5154	Free gift (claimed from mobile 611234567)
200719	2007-07-24 08:15:00	5000.0000	legacy_payment	credit_debit_card	OK	200439	CR0009	Credit Card Deposit
200739	2008-07-24 08:15:00	500000.0000	legacy_payment	credit_debit_card	OK	200459	CR0008	Credit Card Deposit
200759	2008-07-24 08:15:00	5.0000	free_gift	free_gift	OK	200479	CR0006	Free gift (claimed from mobile 441234567890)
200779	2007-02-26 14:29:00	404.0000	legacy_payment	ewallet	OK	200499	CR0005	Egold deposit Batch 76721052 from egold ac 2387346 (0.587209 ounces of Gold at $688.00/ounce) Egold Timestamp 1172500146
200799	2009-07-31 06:03:00	20.0000	free_gift	free_gift	OK	200519	CR0016	Free gift (claimed from mobile 611234549)
200819	2009-08-31 10:03:00	20.0000	free_gift	free_gift	OK	200539	CR0015	Free gift (claimed from mobile 611234549)
200839	2009-07-31 07:10:00	10000.0000	datacash	credit_debit_card	OK	200519	CR0016	datacash credit card deposit ORDERID=77516059288 (71510466288,) TIMESTAMP=31-Jul-09 07h10GMT
200859	2009-08-13 09:52:00	1000.0000	datacash	credit_debit_card	OK	200559	CR5156	BLURB=datacash credit card deposit ORDERID=77515657112 (4800200063243697,) TIMESTAMP=13-Aug-09 09h52GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS
200879	2009-08-13 10:03:00	20.0000	free_gift	free_gift	OK	200559	CR5156	Free gift (claimed from mobile 611234549)
200899	2009-07-31 06:03:00	20.0000	free_gift	free_gift	OK	200579	MLT0016	Free gift (claimed from mobile 611234549)
200919	2009-07-31 07:10:00	10000.0000	datacash	credit_debit_card	OK	200579	MLT0016	datacash credit card deposit ORDERID=775178856288 (77285256348,) TIMESTAMP=31-Jul-09 07h10GMT
200939	2009-08-31 10:03:00	20.0000	free_gift	free_gift	OK	200599	MLT0015	Free gift (claimed from mobile 611234549)
200959	2009-08-13 09:52:00	1000.0000	datacash	credit_debit_card	OK	200619	MLT5156	BLURB=datacash credit card deposit ORDERID=77515657112 (4800200063243697,) TIMESTAMP=13-Aug-09 09h52GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS
200979	2009-08-13 10:03:00	20.0000	free_gift	free_gift	OK	200619	MLT5156	Free gift (claimed from mobile 611234549)
200999	2009-07-15 10:08:00	100.0000	datacash	credit_debit_card	OK	200639	CR0030	BLURB=datacash credit card deposit ORDERID=77705752425 (4500200062818819,) TIMESTAMP=15-Jul-09 10h08GMT CCHH F599A8A4628AA9284913028A352A4E1D V99042100 Delta 3DS
201039	2009-08-14 08:48:00	-100.0000	datacash	credit_debit_card	OK	200639	CR0030	datacash credit card refund 
201059	2009-09-29 04:28:00	15.0000	datacash	credit_debit_card	OK	200639	CR0030	BLURB=datacash credit card deposit ORDERID=77705798535 (4000200063989450,617154) TIMESTAMP=29-Sep-09 04h28GMT CCHH 78674CF5D33148801E771563691DB08F (GBR) V99042100 VISA
201079	2009-09-29 04:30:00	20.0000	datacash	credit_debit_card	OK	200639	CR0030	BLURB=datacash credit card deposit ORDERID=77705798596 (4200200063989454,) TIMESTAMP=29-Sep-09 04h30GMT CCHH 78674CF5D33148801E771563691DB08F V99042100 VISA 3DS
201099	2009-07-31 06:03:00	20.0000	free_gift	free_gift	OK	200679	CR0016	Free gift (claimed from mobile 611234549)
201119	2009-09-29 04:50:00	-15.0000	datacash	credit_debit_card	OK	200639	CR0030	datacash credit card refund 4600200063989640 967473 1254199822 V99042100
201139	2009-07-31 06:03:00	20.0000	free_gift	free_gift	OK	200699	CR0016	Free gift (claimed from mobile 611234549)
201159	2009-07-31 07:10:00	10000.0000	datacash	credit_debit_card	OK	200679	CR0016	datacash credit card deposit ORDERID=775178256288 (77385256388,) TIMESTAMP=31-Jul-09 07h10GMT
201179	2009-09-29 05:52:00	1000.0000	datacash	credit_debit_card	OK	200639	CR0030	BLURB=datacash credit card deposit ORDERID=77705703569 (4200200063989982,817312) TIMESTAMP=29-Sep-09 05h52GMT CCHH 74B32F131EE301ED2D819D443CB718E6 (GBR) V99042100 VISA
201199	2009-07-31 07:10:00	10000.0000	datacash	credit_debit_card	OK	200699	CR0016	datacash credit card deposit ORDERID=775178256287 (77385256387,) TIMESTAMP=31-Jul-09 07h10GMT
201219	2009-09-29 05:58:00	-100.0000	datacash	credit_debit_card	OK	200639	CR0030	datacash credit card refund 4800200063990020 755771 1254203935 V99042100
201239	2009-10-06 08:08:00	-100.0000	datacash	credit_debit_card	OK	200639	CR0030	datacash credit card refund 4300200064129453 514447 1254816486 V99042100
201279	2009-09-10 04:18:00	100.0000	datacash	credit_debit_card	OK	200739	CR5162	BLURB=datacash credit card deposit ORDERID=77516256288 (4900200063643402,) TIMESTAMP=10-Sep-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS
201299	2009-09-10 04:28:00	200.0000	envoy_transfer	bank_money_transfer	OK	200739	CR5162	Envoy deposit
201359	2009-08-31 10:03:00	20.0000	free_gift	free_gift	OK	200779	CR0015	Free gift (claimed from mobile 611234549)
201379	2009-08-13 09:52:00	1000.0000	datacash	credit_debit_card	OK	200799	CR0014	BLURB=datacash credit card deposit ORDERID=77515657112 (4800200063243697,) TIMESTAMP=13-Aug-09 09h52GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS
201399	2009-08-13 10:03:00	20.0000	free_gift	free_gift	OK	200799	CR0014	Free gift (claimed from mobile 611234549)
201459	2007-02-24 13:53:00	10000.0000	legacy_payment	ewallet	OK	200859	MLT16143	Egold deposit Batch 76627601 from egold ac 3113268 (0.153711 ounces of Gold at $683.10/ounce) Egold Timestamp 1172325220
201519	2008-01-15 13:41:00	-50.0000	legacy_payment	ewallet	OK	200859	MLT16143	E-bullion withdrawal from MLT16143 to account D55032 Transaction id A44674209-MXP Timestamp 1200404467 (exchange 1)
201559	2008-01-18 17:33:00	-10.0000	legacy_payment	ewallet	OK	200859	MLT16143	E-bullion withdrawal from MLT16143 to account D55032 Transaction id A76324677-MXP Timestamp 1200677631 (exchange 1)
201579	2008-01-21 15:37:00	-10.0000	legacy_payment	ewallet	OK	200859	MLT16143	E-bullion withdrawal from MLT16143 to account D55032 Transaction id A98323624-MXP Timestamp 1200929831 (exchange 1)
201599	2007-02-12 07:54:00	10000.0000	legacy_payment	cancellation	OK	1202	CR7057	
201659	2005-12-19 01:21:00	5.0400	affiliate_reward	affiliate_reward	OK	200919	AFFILIATE	Reward from affiliate program from 1-Sep-09 to 30-Sep-09
201679	2005-12-19 01:21:00	5.0400	affiliate_reward	affiliate_reward	OK	200939	AFFILIATE	Reward from affiliate program from 1-Sep-09 to 30-Sep-09
201759	2011-02-18 07:32:00	20.0000	transactium_credit_debit_card	credit_debit_card	OK	201039	CR0099	BLURB=transactium credit card deposit ORDERID=772068947928 (916594) TIMESTAMP=18-Feb-11 07h32GMT CCHH 12B361B3CD9E31A7C6012E13AD9BBD0A VISA
201799	2011-06-28 10:07:00	10.0000	moneta	ewallet	OK	201079	CR2002	Moneta deposit ExternalID:CR798051270634820 TransactionID:2628125 AccountNo:93617556 CorrespondingAccountNo:93617556 Amount:USD10.00 Moneta Timestamp 28-Jun-11 10:07:49GMT
201819	2017-05-03 12:34:56	0.00001	ctc	external_cashier	OK	201099	CR1500	no remarks
201839	2020-05-03 09:29:12	20.00	free_gift	free_gift	OK	201119	CR1500	no remarks
201859	2020-05-02 12:29:12	5.00	ctc	external_cashier	OK	201119	CR1500	payment_processor=QIWI
201879	2020-05-01 13:41:00	-50.00	legacy_payment	ewallet	OK	201119	MLT16143	no remark
\.


SET search_path = transaction, pg_catalog;

--
-- Data for Name: transaction; Type: TABLE DATA; Schema: transaction; Owner: postgres
--

-- Disable transaction validation for testing (we will not enable it again!)
ALTER TABLE transaction DISABLE TRIGGER validate_transaction_time_trg;
ALTER TABLE transaction DISABLE TRIGGER update_transaction_first_buy;

COPY transaction (id, account_id, transaction_time, amount, staff_loginid, remark, referrer_type, financial_market_bet_id, payment_id, action_type, quantity, balance_after, source, app_markup) FROM stdin;
200019	200039	2011-01-01 08:00:00	150.00	MX1001	\N	payment	\N	200019	deposit	1	150.00	\N	\N
200039	200039	2011-03-09 06:22:00	2000.00	MX1001	\N	payment	\N	200039	deposit	1	2150.00	\N	\N
200049	200039	2011-03-09 07:22:00	2000.00	MX1001	\N	payment	\N	200059	deposit	1	4150.00	\N	\N
200050	200039	2011-03-09 07:23:00	100.00	MX1001	\N	payment	\N	200069	deposit	1	4250.00	\N	\N
200051	200039	2011-03-09 07:24:00	100.00	MX1001	\N	payment	\N	200070	deposit	1	4350.00	\N	\N
200099	200039	2011-03-09 08:00:00	-100.00	MX1001	\N	payment	\N	200079	withdrawal	1	4250.00	\N	\N
200100	200039	2017-02-21 00:00:00	-100.00	MX1001	\N	financial_market_bet	\N	\N	buy	1	4150.00	1	1
211399	200039	2017-03-09 03:16:00	-25.00	MX1001	\N	financial_market_bet	300040	\N	buy	1	4125.00	\N	\N
211419	200039	2017-03-09 04:16:00	-25.00	MX1001	\N	financial_market_bet	300060	\N	buy	1	4100.00	\N	\N
211429	200039	2017-03-09 04:16:00	-25.00	MX1001	\N	financial_market_bet	300080	\N	buy	1	4075.00	\N	\N
200179	200099	2009-08-13 09:35:00	20.00	CR5154	\N	payment	\N	200159	deposit	1	20.00	\N	\N
200279	200099	2009-08-14 07:19:00	-15.04	CR0013	\N	financial_market_bet	200139	\N	buy	1	4.96	\N	\N
200339	200099	2009-08-14 07:21:00	0.00	CR0013	\N	financial_market_bet	200139	\N	sell	1	4.96	\N	\N
200499	200199	2009-08-13 09:35:00	20.00	MLT5154	\N	payment	\N	200219	deposit	1	20.00	\N	\N
200539	200199	2009-08-14 07:19:00	-15.04	MLT0013	\N	financial_market_bet	200379	\N	buy	1	4.96	\N	\N
200599	200199	2009-08-14 07:21:00	0.00	MLT0013	\N	financial_market_bet	200379	\N	sell	1	4.96	\N	\N
200679	200219	2008-07-24 08:15:00	5000.00	CR0031	\N	payment	\N	200239	deposit	1	5000.00	\N	\N
200719	200219	2010-05-18 09:11:00	-100.00	CR0031	\N	payment	\N	200259	withdrawal	1	4900.00	\N	\N
200779	200219	2010-05-18 09:12:00	-100.00	CR0031	\N	payment	\N	200279	withdrawal	1	4800.00	\N	\N
200839	200219	2010-05-18 09:14:00	-100.00	CR0031	\N	payment	\N	200299	withdrawal	1	4700.00	\N	\N
200899	200219	2010-05-18 09:24:00	-100.00	CR0031	\N	payment	\N	200319	withdrawal	1	4600.00	\N	\N
200959	200219	2010-05-19 09:24:00	-100.00	CR0031	\N	payment	\N	200339	withdrawal	1	4500.00	\N	\N
201039	200259	2009-11-18 10:11:00	6180.00	geokkheng	\N	payment	\N	200379	deposit	1	6280.00	\N	\N
201079	200259	2009-11-18 03:13:00	100.00	CR0029	\N	payment	\N	200439	deposit	1	100.00	\N	\N
201099	200279	2009-11-18 04:18:00	500.00	CR0028	\N	payment	\N	200419	deposit	1	500.00	\N	\N
201139	200299	2009-09-10 04:18:00	1000.00	CR0016	\N	payment	\N	200459	deposit	1	1000.00	\N	\N
201179	200279	2009-11-18 04:18:00	20.00	CR0028	\N	payment	\N	200499	deposit	1	520.00	\N	\N
201199	200299	2009-09-10 04:18:00	20.00	CR0016	\N	payment	\N	200519	deposit	1	1020.00	\N	\N
201239	200279	2009-11-18 08:46:00	-30.00	CR0028	\N	financial_market_bet	200439	\N	buy	1	490.00	\N	\N
201259	200299	2009-10-20 08:46:00	-300.00	CR0016	\N	financial_market_bet	200459	\N	buy	1	720.00	\N	\N
201279	200279	2009-11-18 02:07:00	0.00	CR0028	\N	financial_market_bet	200439	\N	sell	1	0.00	\N	\N
201319	200299	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	200459	\N	sell	1	720.00	\N	\N
201359	200319	2009-09-10 04:18:00	100.00	CR0016	\N	payment	\N	200539	deposit	1	100.00	\N	\N
201399	200359	2005-09-21 06:14:00	600.00	CR0021	\N	payment	\N	200599	deposit	1	600.00	\N	\N
201439	200359	2005-09-21 06:16:00	-5.00	CR0021	\N	financial_market_bet	200499	\N	buy	1	595.00	\N	\N
201499	200359	2005-09-21 06:16:00	9.50	CR0021	\N	financial_market_bet	200499	\N	sell	1	604.50	\N	\N
201659	200359	2005-09-21 06:16:00	-10.00	CR0021	\N	financial_market_bet	200639	\N	buy	1	594.50	\N	\N
201719	200359	2005-09-21 06:17:00	19.00	CR0021	\N	financial_market_bet	200639	\N	sell	1	613.50	\N	\N
201879	200359	2005-09-21 06:18:00	-20.00	CR0021	\N	financial_market_bet	200799	\N	buy	1	593.50	\N	\N
201939	200359	2005-09-21 06:18:00	38.00	CR0021	\N	financial_market_bet	200799	\N	sell	1	631.50	\N	\N
201979	200359	2005-09-21 06:18:00	-5.00	CR0021	\N	financial_market_bet	200819	\N	buy	1	626.50	\N	\N
202039	200359	2005-09-21 06:19:00	9.50	CR0021	\N	financial_market_bet	200819	\N	sell	1	636.00	\N	\N
202179	200359	2005-09-21 06:20:00	-15.00	CR0021	\N	financial_market_bet	200879	\N	buy	1	621.00	\N	\N
202219	200359	2005-09-21 06:20:00	28.50	CR0021	\N	financial_market_bet	200879	\N	sell	1	649.50	\N	\N
202339	200359	2005-09-21 06:21:00	-20.00	CR0021	\N	financial_market_bet	200999	\N	buy	1	629.50	\N	\N
202399	200359	2005-09-21 06:21:00	38.00	CR0021	\N	financial_market_bet	200999	\N	sell	1	667.50	\N	\N
202439	200359	2005-09-21 06:21:00	-10.00	CR0021	\N	financial_market_bet	201059	\N	buy	1	657.50	\N	\N
202479	200359	2005-09-21 06:21:00	19.00	CR0021	\N	financial_market_bet	201059	\N	sell	1	676.50	\N	\N
202579	200359	2005-09-21 06:22:00	-20.00	CR0021	\N	financial_market_bet	201119	\N	buy	1	656.50	\N	\N
202639	200359	2005-09-21 06:22:00	38.00	CR0021	\N	financial_market_bet	201119	\N	sell	1	694.50	\N	\N
202679	200359	2005-09-21 06:22:00	-10.00	CR0021	\N	financial_market_bet	201139	\N	buy	1	684.50	\N	\N
202739	200359	2005-09-21 06:23:00	19.00	CR0021	\N	financial_market_bet	201139	\N	sell	1	703.50	\N	\N
202799	200359	2005-09-21 06:23:00	-10.00	CR0021	\N	financial_market_bet	201199	\N	buy	1	693.50	\N	\N
202859	200359	2005-09-21 06:24:00	19.00	CR0021	\N	financial_market_bet	201199	\N	sell	1	712.50	\N	\N
202899	200359	2005-09-21 06:24:00	-10.00	CR0021	\N	financial_market_bet	201259	\N	buy	1	702.50	\N	\N
202959	200359	2005-09-21 06:24:00	19.00	CR0021	\N	financial_market_bet	201259	\N	sell	1	721.50	\N	\N
202979	200359	2005-09-21 06:24:00	-10.00	CR0021	\N	financial_market_bet	201299	\N	buy	1	711.50	\N	\N
203019	200359	2005-09-21 06:24:00	19.00	CR0021	\N	financial_market_bet	201299	\N	sell	1	730.50	\N	\N
203139	200359	2005-09-21 06:25:00	-10.00	CR0021	\N	financial_market_bet	201419	\N	buy	1	720.50	\N	\N
203159	200359	2005-09-21 06:25:00	19.00	CR0021	\N	financial_market_bet	201419	\N	sell	1	739.50	\N	\N
203199	200359	2005-09-21 06:26:00	-20.00	CR0021	\N	financial_market_bet	201459	\N	buy	1	719.50	\N	\N
203219	200359	2005-09-21 06:26:00	38.00	CR0021	\N	financial_market_bet	201459	\N	sell	1	757.50	\N	\N
203279	200359	2005-09-21 06:27:00	-40.00	CR0021	\N	financial_market_bet	201519	\N	buy	1	717.50	\N	\N
203299	200359	2005-09-21 06:27:00	76.00	CR0021	\N	financial_market_bet	201519	\N	sell	1	793.50	\N	\N
203379	200359	2005-09-21 06:29:00	-20.00	CR0021	\N	financial_market_bet	201599	\N	buy	1	773.50	\N	\N
203399	200359	2005-09-21 06:29:00	38.00	CR0021	\N	financial_market_bet	201599	\N	sell	1	811.50	\N	\N
203419	200359	2005-09-21 06:29:00	-10.00	CR0021	\N	financial_market_bet	201619	\N	buy	1	801.50	\N	\N
203439	200359	2005-09-21 06:29:00	19.00	CR0021	\N	financial_market_bet	201619	\N	sell	1	820.50	\N	\N
203479	200359	2005-09-21 06:30:00	-20.00	CR0021	\N	financial_market_bet	201659	\N	buy	1	800.50	\N	\N
203499	200359	2005-09-21 06:30:00	38.00	CR0021	\N	financial_market_bet	201659	\N	sell	1	838.50	\N	\N
203679	200359	2005-09-21 06:37:00	-10.00	CR0021	\N	financial_market_bet	201839	\N	buy	1	828.50	\N	\N
203699	200359	2005-09-21 06:38:00	19.00	CR0021	\N	financial_market_bet	201839	\N	sell	1	847.50	\N	\N
203719	200359	2005-09-21 06:38:00	-10.00	CR0021	\N	financial_market_bet	201859	\N	buy	1	837.50	\N	\N
203739	200359	2005-09-21 06:38:00	19.00	CR0021	\N	financial_market_bet	201859	\N	sell	1	856.50	\N	\N
203759	200359	2005-09-21 06:38:00	-10.00	CR0021	\N	financial_market_bet	201879	\N	buy	1	846.50	\N	\N
203779	200359	2005-09-21 06:39:00	19.00	CR0021	\N	financial_market_bet	201879	\N	sell	1	865.50	\N	\N
203799	200359	2005-09-21 06:39:00	-10.00	CR0021	\N	financial_market_bet	201899	\N	buy	1	855.50	\N	\N
201379	200339	2007-04-15 21:02:00	10.00	CR0025	\N	payment	\N	200559	deposit	1	10.00	\N	\N
201479	200339	2007-04-16 01:43:00	-5.00	CR0025	\N	financial_market_bet	200519	\N	buy	1	5.00	\N	\N
201539	200339	2007-04-16 01:48:00	-5.00	CR0025	\N	financial_market_bet	200579	\N	buy	1	0.00	\N	\N
201579	200339	2007-04-16 01:53:00	5.00	CR0025	\N	payment	\N	200619	deposit	1	5.00	\N	\N
201619	200339	2007-04-16 02:01:00	-5.00	CR0025	\N	financial_market_bet	200659	\N	buy	1	0.00	\N	\N
201699	200339	2007-04-16 02:33:00	10.00	CR0025	\N	financial_market_bet	200659	\N	sell	1	10.00	\N	\N
201759	200339	2007-04-16 20:18:00	10.00	CR0025	\N	financial_market_bet	200579	\N	sell	1	20.00	\N	\N
201819	200339	2007-04-16 21:34:00	5.00	CR0025	\N	payment	\N	200639	deposit	1	25.00	\N	\N
201919	200339	2007-04-16 21:38:00	10.00	CR0025	\N	financial_market_bet	200519	\N	sell	1	35.00	\N	\N
202019	200379	2009-09-10 04:18:00	100.00	CR0016	\N	payment	\N	200659	deposit	1	100.00	\N	\N
202079	200379	2009-09-10 04:28:00	200.00	CR0016	\N	payment	\N	200679	deposit	1	300.00	\N	\N
202139	200379	2009-10-16 08:27:00	-1.16	CR0016	\N	financial_market_bet	200859	\N	buy	1	298.84	\N	\N
202199	200379	2009-10-20 08:46:00	-7.26	CR0016	\N	financial_market_bet	200899	\N	buy	1	291.58	\N	\N
202239	200379	2009-10-23 05:42:00	-1.04	CR0016	\N	financial_market_bet	200919	\N	buy	1	290.54	\N	\N
202299	200379	2009-10-23 05:43:00	-7.80	CR0016	\N	financial_market_bet	200959	\N	buy	1	282.74	\N	\N
202359	200379	2009-10-23 05:47:00	-7.80	CR0016	\N	financial_market_bet	201019	\N	buy	1	274.94	\N	\N
202419	200379	2009-10-23 05:50:00	-7.80	CR0016	\N	financial_market_bet	201039	\N	buy	1	267.14	\N	\N
202459	200379	2009-10-23 05:56:00	-7.80	CR0016	\N	financial_market_bet	201079	\N	buy	1	259.34	\N	\N
202519	200379	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	200859	\N	sell	1	259.34	\N	\N
202559	200379	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	200899	\N	sell	1	259.34	\N	\N
202599	200379	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	200919	\N	sell	1	259.34	\N	\N
202659	200379	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	200959	\N	sell	1	259.34	\N	\N
202719	200379	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	201019	\N	sell	1	259.34	\N	\N
202779	200379	2009-10-27 02:07:00	15.00	CR0016	\N	financial_market_bet	201039	\N	sell	1	274.34	\N	\N
202839	200379	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	201079	\N	sell	1	274.34	\N	\N
202939	200479	2008-07-24 08:15:00	5.00	CR0006	\N	payment	\N	200759	deposit	1	5.00	\N	\N
201419	200319	2009-09-10 04:28:00	200.00	CR0016	\N	payment	\N	200579	deposit	1	300.00	\N	\N
201459	200319	2009-10-16 08:27:00	-1.16	CR0016	\N	financial_market_bet	200539	\N	buy	1	298.84	\N	\N
201519	200319	2009-10-20 08:46:00	-7.26	CR0016	\N	financial_market_bet	200559	\N	buy	1	291.58	\N	\N
201599	200319	2009-10-23 05:42:00	-1.04	CR0016	\N	financial_market_bet	200619	\N	buy	1	290.54	\N	\N
201639	200319	2009-10-23 05:43:00	-7.80	CR0016	\N	financial_market_bet	200679	\N	buy	1	282.74	\N	\N
201679	200319	2009-10-23 05:47:00	-7.80	CR0016	\N	financial_market_bet	200699	\N	buy	1	274.94	\N	\N
201739	200319	2009-10-23 05:50:00	-7.80	CR0016	\N	financial_market_bet	200719	\N	buy	1	267.14	\N	\N
201799	200319	2009-10-23 05:56:00	-7.80	CR0016	\N	financial_market_bet	200759	\N	buy	1	259.34	\N	\N
201859	200319	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	200539	\N	sell	1	259.34	\N	\N
201899	200319	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	200559	\N	sell	1	259.34	\N	\N
201959	200319	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	200619	\N	sell	1	259.34	\N	\N
201999	200319	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	200679	\N	sell	1	259.34	\N	\N
202059	200319	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	200699	\N	sell	1	259.34	\N	\N
202099	200319	2009-10-27 02:07:00	15.00	CR0016	\N	financial_market_bet	200719	\N	sell	1	274.34	\N	\N
202159	200319	2009-10-27 02:07:00	0.00	CR0016	\N	financial_market_bet	200759	\N	sell	1	274.34	\N	\N
202259	200399	2009-08-13 09:35:00	20.00	CR5154	\N	payment	\N	200699	deposit	1	20.00	\N	\N
202319	200399	2009-08-14 07:19:00	-15.04	CR0013	\N	financial_market_bet	200979	\N	buy	1	4.96	\N	\N
202379	200399	2009-08-14 07:21:00	0.00	CR0013	\N	financial_market_bet	200979	\N	sell	1	4.96	\N	\N
202499	200439	2007-07-24 08:15:00	5000.00	CR0009	\N	payment	\N	200719	deposit	1	5000.00	\N	\N
202619	200459	2008-07-24 08:15:00	500000.00	CR0008	\N	payment	\N	200739	deposit	1	500000.00	\N	\N
202999	200499	2007-02-26 14:29:00	404.00	CR0005	\N	payment	\N	200779	deposit	1	404.00	\N	\N
203819	200359	2005-09-21 06:39:00	19.00	CR0021	\N	financial_market_bet	201899	\N	sell	1	874.50	\N	\N
203839	200359	2005-09-21 06:39:00	-10.00	CR0021	\N	financial_market_bet	201919	\N	buy	1	864.50	\N	\N
203859	200359	2005-09-21 06:39:00	19.00	CR0021	\N	financial_market_bet	201919	\N	sell	1	883.50	\N	\N
203879	200359	2005-09-21 06:40:00	-10.00	CR0021	\N	financial_market_bet	201939	\N	buy	1	873.50	\N	\N
203899	200359	2005-09-21 06:40:00	19.00	CR0021	\N	financial_market_bet	201939	\N	sell	1	892.50	\N	\N
203939	200359	2005-09-21 06:40:00	-20.00	CR0021	\N	financial_market_bet	201979	\N	buy	1	872.50	\N	\N
203959	200359	2005-09-21 06:40:00	38.00	CR0021	\N	financial_market_bet	201979	\N	sell	1	910.50	\N	\N
203979	200359	2005-09-21 06:40:00	-10.00	CR0021	\N	financial_market_bet	201999	\N	buy	1	900.50	\N	\N
203999	200359	2005-09-21 06:41:00	19.00	CR0021	\N	financial_market_bet	201999	\N	sell	1	919.50	\N	\N
204019	200359	2005-09-21 06:41:00	-10.00	CR0021	\N	financial_market_bet	202019	\N	buy	1	909.50	\N	\N
204039	200359	2005-09-21 06:41:00	19.00	CR0021	\N	financial_market_bet	202019	\N	sell	1	928.50	\N	\N
204119	200359	2005-09-21 06:42:00	-100.00	CR0021	\N	financial_market_bet	202099	\N	buy	1	828.50	\N	\N
204139	200359	2005-09-21 06:42:00	190.00	CR0021	\N	financial_market_bet	202099	\N	sell	1	1018.50	\N	\N
204159	200359	2005-09-21 06:42:00	-10.00	CR0021	\N	financial_market_bet	202119	\N	buy	1	1008.50	\N	\N
204179	200359	2005-09-21 06:42:00	19.00	CR0021	\N	financial_market_bet	202119	\N	sell	1	1027.50	\N	\N
204239	200359	2005-09-21 06:43:00	-40.00	CR0021	\N	financial_market_bet	202179	\N	buy	1	987.50	\N	\N
204259	200359	2005-09-21 06:43:00	76.00	CR0021	\N	financial_market_bet	202179	\N	sell	1	1063.50	\N	\N
204279	200359	2005-09-21 06:44:00	-10.00	CR0021	\N	financial_market_bet	202199	\N	buy	1	1053.50	\N	\N
204299	200359	2005-09-21 06:44:00	19.00	CR0021	\N	financial_market_bet	202199	\N	sell	1	1072.50	\N	\N
204419	200359	2005-09-21 06:46:00	-125.00	CR0021	\N	financial_market_bet	202319	\N	buy	1	947.50	\N	\N
204439	200359	2005-09-21 06:46:00	237.50	CR0021	\N	financial_market_bet	202319	\N	sell	1	1185.00	\N	\N
204479	200519	2009-07-31 06:03:00	20.00	CR0016	\N	payment	\N	200799	deposit	1	20.00	\N	\N
204499	200539	2009-08-31 10:03:00	20.00	CR0015	\N	payment	\N	200819	deposit	1	20.00	\N	\N
204519	200519	2009-07-31 07:10:00	10000.00	CR0016	\N	payment	\N	200839	deposit	1	10020.00	\N	\N
204539	200559	2009-08-13 09:52:00	1000.00	CR5156	\N	payment	\N	200859	deposit	1	1000.00	\N	\N
204559	200519	2009-07-31 08:21:00	-3140.00	CR0016	\N	financial_market_bet	202359	\N	buy	1	6880.00	\N	\N
204579	200559	2009-08-13 10:03:00	20.00	CR5156	\N	payment	\N	200879	deposit	1	1020.00	\N	\N
204599	200579	2009-07-31 06:03:00	20.00	MLT0016	\N	payment	\N	200899	deposit	1	20.00	\N	\N
204619	200519	2009-07-31 23:48:00	0.00	CR0016	\N	financial_market_bet	202359	\N	sell	1	6880.00	\N	\N
204639	200579	2009-07-31 07:10:00	10000.00	MLT0016	\N	payment	\N	200919	deposit	1	10020.00	\N	\N
204679	200599	2009-08-31 10:03:00	20.00	MLT0015	\N	payment	\N	200939	deposit	1	20.00	\N	\N
204699	200579	2009-07-31 08:21:00	-3140.00	MLT0016	\N	financial_market_bet	202399	\N	buy	1	6880.00	\N	\N
204739	200579	2009-07-31 23:48:00	0.00	MLT0016	\N	financial_market_bet	202399	\N	sell	1	6880.00	\N	\N
204759	200619	2009-08-13 09:52:00	1000.00	MLT5156	\N	payment	\N	200959	deposit	1	1000.00	\N	\N
204779	200619	2009-08-13 10:03:00	20.00	MLT5156	\N	payment	\N	200979	deposit	1	1020.00	\N	\N
204799	200639	2009-07-15 10:08:00	100.00	CR0030	\N	payment	\N	200999	deposit	1	100.00	\N	\N
204839	200639	2009-08-14 08:48:00	-100.00	CR0030	\N	payment	\N	201039	withdrawal	1	0.00	\N	\N
204899	200639	2009-09-29 04:28:00	15.00	CR0030	\N	payment	\N	201059	deposit	1	15.00	\N	\N
204959	200639	2009-09-29 04:30:00	20.00	CR0030	\N	payment	\N	201079	deposit	1	35.00	\N	\N
204979	200679	2009-07-31 06:03:00	20.00	CR0016	\N	payment	\N	201099	deposit	1	20.00	\N	\N
204999	200639	2009-09-29 04:50:00	-15.00	CR0030	\N	payment	\N	201119	withdrawal	1	20.00	\N	\N
205019	200699	2009-07-31 06:03:00	20.00	CR0016	\N	payment	\N	201139	deposit	1	20.00	\N	\N
205039	200679	2009-07-31 07:10:00	10000.00	CR0016	\N	payment	\N	201159	deposit	1	10020.00	\N	\N
205059	200639	2009-09-29 05:52:00	1000.00	CR0030	\N	payment	\N	201179	deposit	1	1020.00	\N	\N
205079	200699	2009-07-31 07:10:00	10000.00	CR0016	\N	payment	\N	201199	deposit	1	10020.00	\N	\N
205099	200679	2009-07-31 08:21:00	-3140.00	CR0016	\N	financial_market_bet	202499	\N	buy	1	6880.00	\N	\N
205119	200699	2009-07-31 08:21:00	-3140.00	CR0016	\N	financial_market_bet	202519	\N	buy	1	6880.00	\N	\N
205139	200639	2009-09-29 05:53:00	-5.00	CR0030	\N	financial_market_bet	202539	\N	buy	1	1015.00	\N	\N
205159	200679	2009-07-31 10:48:00	10000.00	CR0016	\N	financial_market_bet	202499	\N	sell	1	16880.00	\N	\N
205179	200699	2009-07-31 10:48:00	10000.00	CR0016	\N	financial_market_bet	202519	\N	sell	1	16880.00	\N	\N
205199	200639	2009-09-29 05:58:00	-100.00	CR0030	\N	payment	\N	201219	withdrawal	1	915.00	\N	\N
205219	200679	2009-07-31 11:21:00	-3140.00	CR0016	\N	financial_market_bet	202559	\N	buy	1	13740.00	\N	\N
205279	200679	2009-07-31 12:48:00	10000.00	CR0016	\N	financial_market_bet	202559	\N	sell	1	23740.00	\N	\N
205339	200679	2009-07-31 13:21:00	-3140.00	CR0016	\N	financial_market_bet	202619	\N	buy	1	20600.00	\N	\N
205399	200679	2009-07-31 14:48:00	10000.00	CR0016	\N	financial_market_bet	202619	\N	sell	1	30600.00	\N	\N
205459	200679	2009-07-31 15:21:00	-3140.00	CR0016	\N	financial_market_bet	202659	\N	buy	1	27460.00	\N	\N
205539	200679	2009-07-31 16:48:00	10000.00	CR0016	\N	financial_market_bet	202659	\N	sell	1	37460.00	\N	\N
205599	200679	2009-07-31 17:21:00	-3140.00	CR0016	\N	financial_market_bet	202739	\N	buy	1	34320.00	\N	\N
205659	200679	2009-07-31 18:48:00	10000.00	CR0016	\N	financial_market_bet	202739	\N	sell	1	44320.00	\N	\N
205719	200679	2009-07-31 19:21:00	-3140.00	CR0016	\N	financial_market_bet	202819	\N	buy	1	41180.00	\N	\N
205779	200679	2009-07-31 20:48:00	10000.00	CR0016	\N	financial_market_bet	202819	\N	sell	1	51180.00	\N	\N
205839	200679	2009-07-31 21:21:00	-3140.00	CR0016	\N	financial_market_bet	202879	\N	buy	1	48040.00	\N	\N
205899	200679	2009-07-31 22:48:00	0.00	CR0016	\N	financial_market_bet	202879	\N	sell	1	48040.00	\N	\N
205959	200679	2009-07-31 23:21:00	-3140.00	CR0016	\N	financial_market_bet	202919	\N	buy	1	44900.00	\N	\N
206019	200679	2009-07-31 23:48:00	10000.00	CR0016	\N	financial_market_bet	202919	\N	sell	1	54900.00	\N	\N
206079	200679	2009-07-31 23:49:00	-10.00	CR0016	\N	financial_market_bet	202979	\N	buy	1	54890.00	\N	\N
206139	200679	2009-07-31 23:49:00	19.00	CR0016	\N	financial_market_bet	202979	\N	sell	1	54909.00	\N	\N
206199	200739	2009-09-10 04:18:00	100.00	CR5162	\N	payment	\N	201279	deposit	1	100.00	\N	\N
206259	200739	2009-09-10 04:28:00	200.00	CR5162	\N	payment	\N	201299	deposit	1	300.00	\N	\N
205239	200699	2009-07-31 11:21:00	-3140.00	CR0016	\N	financial_market_bet	202579	\N	buy	1	13740.00	\N	\N
205299	200699	2009-07-31 12:48:00	10000.00	CR0016	\N	financial_market_bet	202579	\N	sell	1	23740.00	\N	\N
205359	200699	2009-07-31 13:21:00	-3140.00	CR0016	\N	financial_market_bet	202639	\N	buy	1	20600.00	\N	\N
205419	200699	2009-07-31 14:48:00	10000.00	CR0016	\N	financial_market_bet	202639	\N	sell	1	30600.00	\N	\N
205479	200699	2009-07-31 15:21:00	-3140.00	CR0016	\N	financial_market_bet	202679	\N	buy	1	27460.00	\N	\N
205519	200699	2009-07-31 16:48:00	10000.00	CR0016	\N	financial_market_bet	202679	\N	sell	1	37460.00	\N	\N
205579	200699	2009-07-31 17:21:00	-3140.00	CR0016	\N	financial_market_bet	202719	\N	buy	1	34320.00	\N	\N
205639	200699	2009-07-31 18:48:00	10000.00	CR0016	\N	financial_market_bet	202719	\N	sell	1	44320.00	\N	\N
205699	200699	2009-07-31 19:21:00	-3140.00	CR0016	\N	financial_market_bet	202799	\N	buy	1	41180.00	\N	\N
205759	200699	2009-07-31 20:48:00	10000.00	CR0016	\N	financial_market_bet	202799	\N	sell	1	51180.00	\N	\N
205819	200699	2009-07-31 21:21:00	-3140.00	CR0016	\N	financial_market_bet	202859	\N	buy	1	48040.00	\N	\N
205879	200699	2009-07-31 22:48:00	10000.00	CR0016	\N	financial_market_bet	202859	\N	sell	1	58040.00	\N	\N
205919	200699	2009-07-31 23:21:00	-3140.00	CR0016	\N	financial_market_bet	202899	\N	buy	1	54900.00	\N	\N
205979	200699	2009-07-31 23:48:00	10000.00	CR0016	\N	financial_market_bet	202899	\N	sell	1	64900.00	\N	\N
206039	200699	2009-07-31 23:49:00	-10.00	CR0016	\N	financial_market_bet	202959	\N	buy	1	64890.00	\N	\N
206099	200699	2009-07-31 23:49:00	19.00	CR0016	\N	financial_market_bet	202959	\N	sell	1	64909.00	\N	\N
206419	200779	2009-08-31 10:03:00	20.00	CR0015	\N	payment	\N	201359	deposit	1	20.00	\N	\N
206479	200799	2009-08-13 09:52:00	1000.00	CR0014	\N	payment	\N	201379	deposit	1	1000.00	\N	\N
206539	200799	2009-08-13 10:03:00	20.00	CR0014	\N	payment	\N	201399	deposit	1	1020.00	\N	\N
206719	200799	2009-11-09 09:59:00	-46.80	CR0014	\N	financial_market_bet	203239	\N	buy	1	973.20	\N	\N
206779	200799	2009-11-09 10:00:00	90.00	CR0014	\N	financial_market_bet	203239	\N	sell	1	1063.20	\N	\N
205259	200639	2009-09-30 09:59:00	0.00	CR0030	\N	financial_market_bet	202539	\N	sell	1	915.00	\N	\N
205319	200639	2009-09-30 10:20:00	-5.21	CR0030	\N	financial_market_bet	202599	\N	buy	1	909.79	\N	\N
205379	200639	2009-10-02 04:59:00	0.00	CR0030	\N	financial_market_bet	202599	\N	sell	1	909.79	\N	\N
205439	200639	2009-10-06 08:08:00	-100.00	CR0030	\N	payment	\N	201239	withdrawal	1	809.79	\N	\N
205499	200639	2009-10-07 04:00:00	-6.13	CR0030	\N	financial_market_bet	202699	\N	buy	1	803.66	\N	\N
205559	200639	2009-10-09 01:17:00	10.00	CR0030	\N	financial_market_bet	202699	\N	sell	1	813.66	\N	\N
205619	200639	2009-11-03 07:14:00	-1.04	CR0030	\N	financial_market_bet	202759	\N	buy	1	812.62	\N	\N
205679	200639	2009-11-03 07:15:00	-10.80	CR0030	\N	financial_market_bet	202779	\N	buy	1	801.82	\N	\N
205739	200639	2009-11-03 07:17:00	-38.47	CR0030	\N	financial_market_bet	202839	\N	buy	1	763.35	\N	\N
205799	200639	2009-11-04 10:40:00	0.00	CR0030	\N	financial_market_bet	202759	\N	sell	1	763.35	\N	\N
205859	200639	2009-11-04 10:40:00	0.00	CR0030	\N	financial_market_bet	202779	\N	sell	1	763.35	\N	\N
205939	200639	2009-11-04 10:40:00	0.00	CR0030	\N	financial_market_bet	202839	\N	sell	1	763.35	\N	\N
205999	200639	2009-11-04 10:41:00	-1.04	CR0030	\N	financial_market_bet	202939	\N	buy	1	762.31	\N	\N
206059	200639	2009-11-04 10:47:00	0.00	CR0030	\N	financial_market_bet	202939	\N	sell	1	762.31	\N	\N
206159	200639	2009-11-05 03:33:00	-1.08	CR0030	\N	financial_market_bet	203019	\N	buy	1	761.23	\N	\N
206219	200639	2009-11-05 05:19:00	0.00	CR0030	\N	financial_market_bet	203019	\N	sell	1	761.23	\N	\N
206279	200639	2009-11-05 05:46:00	-23.66	CR0030	\N	financial_market_bet	203059	\N	buy	1	737.57	\N	\N
206319	200639	2009-11-05 05:52:00	0.00	CR0030	\N	financial_market_bet	203059	\N	sell	1	737.57	\N	\N
206379	200639	2009-11-05 06:33:00	-9.77	CR0030	\N	financial_market_bet	203099	\N	buy	1	727.80	\N	\N
206439	200639	2009-11-05 06:34:00	-9.77	CR0030	\N	financial_market_bet	203119	\N	buy	1	718.03	\N	\N
206499	200639	2009-11-09 02:22:00	-32.46	CR0030	\N	financial_market_bet	203159	\N	buy	1	685.57	\N	\N
206559	200639	2009-11-09 04:57:00	60.00	CR0030	\N	financial_market_bet	203159	\N	sell	1	745.57	\N	\N
206579	200639	2009-11-09 06:46:00	40.00	CR0030	\N	financial_market_bet	203099	\N	sell	2	785.57	\N	\N
206639	200639	2009-11-09 06:50:00	-10.40	CR0030	\N	financial_market_bet	203199	\N	buy	1	775.17	\N	\N
206679	200639	2009-11-09 06:52:00	20.00	CR0030	\N	financial_market_bet	203199	\N	sell	1	795.17	\N	\N
206739	200639	2009-11-09 06:52:00	-10.40	CR0030	\N	financial_market_bet	203259	\N	buy	1	784.77	\N	\N
206799	200639	2009-11-09 06:54:00	0.00	CR0030	\N	financial_market_bet	203259	\N	sell	1	784.77	\N	\N
206839	200639	2009-11-09 09:59:00	-46.80	CR0030	\N	financial_market_bet	203319	\N	buy	1	737.97	\N	\N
206879	200639	2009-11-09 10:00:00	-46.80	CR0030	\N	financial_market_bet	203359	\N	buy	1	691.17	\N	\N
206899	200639	2009-11-09 10:00:00	90.00	CR0030	\N	financial_market_bet	203319	\N	sell	1	781.17	\N	\N
206919	200639	2009-11-09 10:00:00	-46.80	CR0030	\N	financial_market_bet	203379	\N	buy	1	734.37	\N	\N
206939	200639	2009-11-09 10:01:00	0.00	CR0030	\N	financial_market_bet	203359	\N	sell	1	734.37	\N	\N
206959	200639	2009-11-09 10:01:00	0.00	CR0030	\N	financial_market_bet	203379	\N	sell	1	734.37	\N	\N
206999	200639	2009-11-10 08:55:00	-10.40	CR0030	\N	financial_market_bet	203419	\N	buy	1	723.97	\N	\N
207019	200639	2009-11-10 08:56:00	0.00	CR0030	\N	financial_market_bet	203419	\N	sell	1	723.97	\N	\N
207039	200639	2009-11-10 08:56:00	-10.40	CR0030	\N	financial_market_bet	203439	\N	buy	1	713.57	\N	\N
207059	200639	2009-11-10 08:57:00	0.00	CR0030	\N	financial_market_bet	203439	\N	sell	1	713.57	\N	\N
207079	200639	2009-11-10 09:20:00	-10.40	CR0030	\N	financial_market_bet	203459	\N	buy	1	703.17	\N	\N
207099	200639	2009-11-10 09:39:00	-10.40	CR0030	\N	financial_market_bet	203479	\N	buy	1	692.77	\N	\N
207119	200639	2009-11-10 09:39:00	0.00	CR0030	\N	financial_market_bet	203459	\N	sell	1	692.77	\N	\N
207139	200639	2009-11-10 09:48:00	20.00	CR0030	\N	financial_market_bet	203479	\N	sell	1	712.77	\N	\N
207159	200639	2009-11-10 09:48:00	-10.40	CR0030	\N	financial_market_bet	203499	\N	buy	1	702.37	\N	\N
207179	200639	2009-11-10 09:50:00	0.00	CR0030	\N	financial_market_bet	203499	\N	sell	1	702.37	\N	\N
207199	200639	2009-11-10 09:50:00	-10.40	CR0030	\N	financial_market_bet	203519	\N	buy	1	691.97	\N	\N
207219	200639	2009-11-10 09:55:00	-10.40	CR0030	\N	financial_market_bet	203539	\N	buy	1	681.57	\N	\N
207239	200639	2009-11-10 09:55:00	0.00	CR0030	\N	financial_market_bet	203519	\N	sell	1	681.57	\N	\N
207259	200639	2009-11-10 09:56:00	20.00	CR0030	\N	financial_market_bet	203539	\N	sell	1	701.57	\N	\N
207279	200639	2009-11-10 09:59:00	-10.40	CR0030	\N	financial_market_bet	203559	\N	buy	1	691.17	\N	\N
207299	200639	2009-11-10 09:59:00	-10.40	CR0030	\N	financial_market_bet	203579	\N	buy	1	680.77	\N	\N
207319	200639	2009-11-10 09:59:00	-10.40	CR0030	\N	financial_market_bet	203599	\N	buy	1	670.37	\N	\N
207339	200639	2009-11-10 09:59:00	-10.40	CR0030	\N	financial_market_bet	203619	\N	buy	1	659.97	\N	\N
207359	200639	2009-11-11 01:56:00	-1.04	CR0030	\N	financial_market_bet	203639	\N	buy	1	658.93	\N	\N
207379	200639	2009-11-11 02:00:00	-1.04	CR0030	\N	financial_market_bet	203659	\N	buy	1	657.89	\N	\N
207399	200639	2009-11-11 02:34:00	0.00	CR0030	\N	financial_market_bet	203599	\N	sell	1	657.89	\N	\N
207419	200639	2009-11-11 02:34:00	2.00	CR0030	\N	financial_market_bet	203659	\N	sell	1	659.89	\N	\N
207439	200639	2009-11-11 02:34:00	2.00	CR0030	\N	financial_market_bet	203639	\N	sell	1	661.89	\N	\N
207459	200639	2009-11-11 02:34:00	0.00	CR0030	\N	financial_market_bet	203619	\N	sell	1	661.89	\N	\N
207479	200639	2009-11-11 02:34:00	0.00	CR0030	\N	financial_market_bet	203579	\N	sell	1	661.89	\N	\N
207499	200639	2009-11-11 02:34:00	20.00	CR0030	\N	financial_market_bet	203559	\N	sell	1	681.89	\N	\N
207519	200639	2009-11-11 02:34:00	-1.04	CR0030	\N	financial_market_bet	203679	\N	buy	1	680.85	\N	\N
207539	200639	2009-11-11 02:35:00	2.00	CR0030	\N	financial_market_bet	203679	\N	sell	1	682.85	\N	\N
207559	200639	2009-11-11 02:39:00	-1.04	CR0030	\N	financial_market_bet	203699	\N	buy	1	681.81	\N	\N
207579	200639	2009-11-11 02:39:00	-46.80	CR0030	\N	financial_market_bet	203719	\N	buy	1	635.01	\N	\N
207599	200639	2009-11-11 02:39:00	2.00	CR0030	\N	financial_market_bet	203699	\N	sell	1	637.01	\N	\N
207619	200639	2009-11-11 02:41:00	0.00	CR0030	\N	financial_market_bet	203719	\N	sell	1	637.01	\N	\N
207639	200639	2009-11-11 07:50:00	-1.04	CR0030	\N	financial_market_bet	203739	\N	buy	1	635.97	\N	\N
207659	200639	2009-11-11 08:09:00	0.00	CR0030	\N	financial_market_bet	203739	\N	sell	1	635.97	\N	\N
207679	200639	2009-11-12 04:08:00	-1.04	CR0030	\N	financial_market_bet	203759	\N	buy	1	634.93	\N	\N
207699	200639	2009-11-12 04:43:00	0.00	CR0030	\N	financial_market_bet	203759	\N	sell	1	634.93	\N	\N
207719	200859	2007-02-24 13:53:00	10000.00	MLT16143	\N	payment	\N	201459	deposit	1	10000.00	\N	\N
207779	200859	2008-01-15 13:41:00	-50.00	MLT16143	\N	payment	\N	201519	withdrawal	1	9950.00	\N	\N
207839	200859	2008-01-18 17:33:00	-10.00	MLT16143	\N	payment	\N	201559	withdrawal	1	9940.00	\N	\N
207899	200859	2008-01-21 15:37:00	-10.00	MLT16143	\N	payment	\N	201579	withdrawal	1	9930.00	\N	\N
207979	1202	2007-02-12 07:54:00	10000.00	CR7057	\N	payment	\N	201599	deposit	1	10000.00	\N	\N
208099	1202	2009-05-05 02:18:00	-18.10	CR7057	\N	financial_market_bet	203959	\N	buy	1	9981.90	\N	\N
208339	1202	2009-05-07 09:55:00	-30.82	CR0010	\N	financial_market_bet	204099	\N	buy	1	9951.08	\N	\N
208399	1202	2009-05-07 09:55:00	-30.82	CR0010	\N	financial_market_bet	204139	\N	buy	1	9920.26	\N	\N
208459	1202	2009-05-07 09:56:00	-30.82	CR0010	\N	financial_market_bet	204159	\N	buy	1	9889.44	\N	\N
208519	1202	2009-05-07 09:58:00	-30.82	CR0010	\N	financial_market_bet	204199	\N	buy	1	9858.62	\N	\N
208579	1202	2009-05-08 02:16:00	-30.82	CR0010	\N	financial_market_bet	204219	\N	buy	1	9827.80	\N	\N
208639	1202	2009-05-08 02:20:00	-30.82	CR0010	\N	financial_market_bet	204259	\N	buy	1	9796.98	\N	\N
208679	1202	2009-05-08 02:20:00	8.32	CR0010	\N	financial_market_bet	203959	\N	sell	1	9805.30	\N	\N
208719	1202	2009-05-08 02:22:00	-30.82	CR0010	\N	financial_market_bet	204299	\N	buy	1	9774.48	\N	\N
208759	1202	2009-05-08 02:22:00	8.32	CR0010	\N	financial_market_bet	204099	\N	sell	1	9782.80	\N	\N
208799	1202	2009-05-08 02:22:00	-30.82	CR0010	\N	financial_market_bet	204319	\N	buy	1	9751.98	\N	\N
208839	1202	2009-05-08 02:22:00	8.32	CR0010	\N	financial_market_bet	204139	\N	sell	1	9760.30	\N	\N
208879	1202	2009-05-08 02:49:00	-30.82	CR0010	\N	financial_market_bet	204359	\N	buy	1	9729.48	\N	\N
208919	1202	2009-05-08 02:49:00	8.32	CR0010	\N	financial_market_bet	204159	\N	sell	1	9737.80	\N	\N
208959	1202	2009-05-08 02:50:00	-30.82	CR0010	\N	financial_market_bet	204399	\N	buy	1	9706.98	\N	\N
208999	1202	2009-05-08 02:50:00	8.32	CR0010	\N	financial_market_bet	204199	\N	sell	1	9715.30	\N	\N
209039	1202	2009-05-08 02:52:00	-30.82	CR0010	\N	financial_market_bet	204439	\N	buy	1	9684.48	\N	\N
209079	1202	2009-05-08 02:52:00	8.32	CR0010	\N	financial_market_bet	204219	\N	sell	1	9692.80	\N	\N
209119	1202	2009-05-08 02:59:00	-30.82	CR0010	\N	financial_market_bet	204479	\N	buy	1	9661.98	\N	\N
209159	1202	2009-05-08 02:59:00	8.32	CR0010	\N	financial_market_bet	204259	\N	sell	1	9670.30	\N	\N
209199	1202	2009-05-08 03:03:00	-30.82	CR0010	\N	financial_market_bet	204519	\N	buy	1	9639.48	\N	\N
209239	1202	2009-05-08 03:03:00	8.32	CR0010	\N	financial_market_bet	204299	\N	sell	1	9647.80	\N	\N
209279	1202	2009-05-08 03:06:00	-30.82	CR0010	\N	financial_market_bet	204559	\N	buy	1	9616.98	\N	\N
209319	1202	2009-05-08 03:06:00	8.32	CR0010	\N	financial_market_bet	204319	\N	sell	1	9625.30	\N	\N
209379	1202	2009-05-08 03:07:00	-30.82	CR0010	\N	financial_market_bet	204619	\N	buy	1	9594.48	\N	\N
209419	1202	2009-05-08 03:07:00	8.32	CR0010	\N	financial_market_bet	204359	\N	sell	1	9602.80	\N	\N
209459	1202	2009-05-08 03:08:00	-30.82	CR0010	\N	financial_market_bet	204659	\N	buy	1	9571.98	\N	\N
209499	1202	2009-05-08 03:08:00	8.32	CR0010	\N	financial_market_bet	204399	\N	sell	1	9580.30	\N	\N
209539	1202	2009-05-08 03:08:00	-30.82	CR0010	\N	financial_market_bet	204699	\N	buy	1	9549.48	\N	\N
209579	1202	2009-05-08 03:08:00	8.32	CR0010	\N	financial_market_bet	204439	\N	sell	1	9557.80	\N	\N
209619	1202	2009-05-08 03:42:00	-30.82	CR0010	\N	financial_market_bet	204739	\N	buy	1	9526.98	\N	\N
209659	1202	2009-05-08 03:42:00	8.32	CR0010	\N	financial_market_bet	204479	\N	sell	1	9535.30	\N	\N
209699	1202	2009-05-08 03:47:00	-30.82	CR0010	\N	financial_market_bet	204799	\N	buy	1	9504.48	\N	\N
209739	1202	2009-05-08 03:47:00	8.32	CR0010	\N	financial_market_bet	204519	\N	sell	1	9512.80	\N	\N
209779	1202	2009-05-08 03:47:00	-30.82	CR0010	\N	financial_market_bet	204839	\N	buy	1	9481.98	\N	\N
209819	1202	2009-05-08 03:47:00	8.32	CR0010	\N	financial_market_bet	204559	\N	sell	1	9490.30	\N	\N
209859	1202	2009-05-08 03:55:00	-30.82	CR0010	\N	financial_market_bet	204879	\N	buy	1	9459.48	\N	\N
209899	1202	2009-05-08 03:55:00	8.32	CR0010	\N	financial_market_bet	204619	\N	sell	1	9467.80	\N	\N
209939	1202	2009-05-08 04:15:00	-30.82	CR0010	\N	financial_market_bet	204919	\N	buy	1	9436.98	\N	\N
209979	1202	2009-05-08 04:15:00	8.32	CR0010	\N	financial_market_bet	204659	\N	sell	1	9445.30	\N	\N
210019	1202	2009-05-08 04:18:00	-30.82	CR0010	\N	financial_market_bet	204959	\N	buy	1	9414.48	\N	\N
210059	1202	2009-05-08 04:18:00	8.32	CR0010	\N	financial_market_bet	204699	\N	sell	1	9422.80	\N	\N
210099	1202	2009-05-08 04:19:00	-30.82	CR0010	\N	financial_market_bet	204999	\N	buy	1	9391.98	\N	\N
210139	1202	2009-05-08 04:19:00	8.32	CR0010	\N	financial_market_bet	204739	\N	sell	1	9400.30	\N	\N
210179	1202	2009-05-08 04:20:00	-30.82	CR0010	\N	financial_market_bet	205039	\N	buy	1	9369.48	\N	\N
210219	1202	2009-05-08 04:20:00	8.32	CR0010	\N	financial_market_bet	204799	\N	sell	1	9377.80	\N	\N
210259	1202	2009-05-08 04:23:00	-30.82	CR0010	\N	financial_market_bet	205079	\N	buy	1	9346.98	\N	\N
210299	1202	2009-05-08 04:23:00	8.32	CR0010	\N	financial_market_bet	204839	\N	sell	1	9355.30	\N	\N
210339	1202	2009-05-08 04:23:00	-30.82	CR0010	\N	financial_market_bet	205119	\N	buy	1	9324.48	\N	\N
210379	1202	2009-05-08 04:23:00	8.32	CR0010	\N	financial_market_bet	204879	\N	sell	1	9332.80	\N	\N
210419	1202	2009-05-08 06:17:00	-30.82	CR0010	\N	financial_market_bet	205159	\N	buy	1	9301.98	\N	\N
210459	1202	2009-05-08 06:17:00	8.32	CR0010	\N	financial_market_bet	204919	\N	sell	1	9310.30	\N	\N
210499	1202	2009-05-08 06:20:00	-30.82	CR0010	\N	financial_market_bet	205199	\N	buy	1	9279.48	\N	\N
210539	1202	2009-05-08 06:20:00	8.32	CR0010	\N	financial_market_bet	204959	\N	sell	1	9287.80	\N	\N
210579	1202	2009-05-08 06:20:00	-30.82	CR0010	\N	financial_market_bet	205239	\N	buy	1	9256.98	\N	\N
210619	1202	2009-05-08 06:20:00	8.32	CR0010	\N	financial_market_bet	204999	\N	sell	1	9265.30	\N	\N
210659	1202	2009-05-08 06:26:00	-30.82	CR0010	\N	financial_market_bet	205279	\N	buy	1	9234.48	\N	\N
210699	1202	2009-05-08 06:26:00	8.32	CR0010	\N	financial_market_bet	205039	\N	sell	1	9242.80	\N	\N
210739	1202	2009-05-08 06:27:00	-30.82	CR0010	\N	financial_market_bet	205319	\N	buy	1	9211.98	\N	\N
210779	1202	2009-05-08 06:27:00	8.32	CR0010	\N	financial_market_bet	205079	\N	sell	1	9220.30	\N	\N
210819	1202	2009-05-08 06:28:00	-30.82	CR0010	\N	financial_market_bet	205359	\N	buy	1	9189.48	\N	\N
210859	1202	2009-05-08 06:28:00	8.32	CR0010	\N	financial_market_bet	205119	\N	sell	1	9197.80	\N	\N
210939	1202	2009-05-08 06:29:00	8.32	CR0010	\N	financial_market_bet	205159	\N	sell	1	9206.12	\N	\N
211019	1202	2009-05-08 06:30:00	8.32	CR0010	\N	financial_market_bet	205199	\N	sell	1	9214.44	\N	\N
211099	1202	2009-05-08 06:31:00	8.32	CR0010	\N	financial_market_bet	205239	\N	sell	1	9222.76	\N	\N
211179	1202	2009-05-08 06:36:00	8.32	CR0010	\N	financial_market_bet	205279	\N	sell	1	9231.08	\N	\N
211259	1202	2009-05-08 06:42:00	8.32	CR0010	\N	financial_market_bet	205319	\N	sell	1	9239.40	\N	\N
211339	1202	2009-05-08 06:43:00	8.32	CR0010	\N	financial_market_bet	205359	\N	sell	1	9247.72	\N	\N
211359	1202	2017-03-09 02:16:00	-25.00	CR0010	\N	financial_market_bet	300000	\N	buy	1	9222.72	\N	\N
211379	1202	2017-03-09 03:16:00	-25.00	CR0010	\N	financial_market_bet	300020	\N	buy	1	9197.72	\N	\N
211679	200919	2005-12-19 01:21:00	5.04	AFFILIATE	\N	payment	\N	201659	deposit	1	5.04	\N	\N
211699	200939	2005-12-19 01:21:00	5.04	AFFILIATE	\N	payment	\N	201679	deposit	1	5.04	\N	\N
212059	201039	2011-02-18 07:32:00	20.00	CR0099	\N	payment	\N	201759	deposit	1	20.00	\N	\N
212099	201079	2011-06-28 10:07:00	10.00	CR2002	\N	payment	\N	201799	deposit	1	10.00	\N	\N
\.

ALTER TABLE transaction ENABLE TRIGGER update_transaction_first_buy;

SET search_path = payment, pg_catalog;

--
-- Data for Name: affiliate_reward; Type: TABLE DATA; Schema: payment; Owner: postgres
--

COPY affiliate_reward (payment_id, reward_from_date, reward_to_date) FROM stdin;
201659	2009-09-01	2009-09-30
201679	2009-09-01	2009-09-30
\.


--
-- Data for Name: bank_wire; Type: TABLE DATA; Schema: payment; Owner: postgres
--

COPY bank_wire (payment_id, client_name, bom_bank_info, date_received, bank_reference, bank_name, bank_address, bank_account_number, bank_account_name, iban, sort_code, swift, aba, extra_info) FROM stdin;
200379	Sutrisno Suryoputro	RBSI 5880-58269864	2009-11-18 00:00:00	46510567									Bank Name  HSBC Bank; Acct No  007-059066-081; Acct Name  Sutrisno Suryoputro
\.


--
-- Data for Name: doughflow; Type: TABLE DATA; Schema: payment; Owner: postgres
--

COPY doughflow (payment_id, transaction_type, trace_id, created_by, payment_processor, ip_address, transaction_id) FROM stdin;
12003	deposit	1	DFHelpDesk	Manual		
\.


--
-- Data for Name: free_gift; Type: TABLE DATA; Schema: payment; Owner: postgres
--

COPY free_gift (payment_id, promotional_code, reason) FROM stdin;
200159	\N	Free gift (claimed from mobile 611234567)
200219	\N	Free gift (claimed from mobile 611234567)
200439	\N	Free gift (claimed from mobile 611231242)
200499	\N	Free gift (claimed from mobile 6712345678) (4900200063643402,) TIMESTAMP=18-Nov-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS 
200519	\N	Free gift (claimed from mobile 611234549) (4900200063643402,) TIMESTAMP=10-Sep-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS 
200699	\N	Free gift (claimed from mobile 611234567)
200759	\N	Free gift (claimed from mobile 441234567890)
200799	\N	Free gift (claimed from mobile 611234549)
200819	\N	Free gift (claimed from mobile 611234549)
200879	\N	Free gift (claimed from mobile 611234549)
200899	\N	Free gift (claimed from mobile 611234549)
200939	\N	Free gift (claimed from mobile 611234549)
200979	\N	Free gift (claimed from mobile 611234549)
201099	\N	Free gift (claimed from mobile 611234549)
201139	\N	Free gift (claimed from mobile 611234549)
201359	\N	Free gift (claimed from mobile 611234549)
201399	\N	Free gift (claimed from mobile 611234549)
\.

--
-- Data for Name: legacy_payment; Type: TABLE DATA; Schema: payment; Owner: postgres
--

COPY legacy_payment (payment_id, legacy_type) FROM stdin;
200019	compacted_statement
200059	misc
200069	misc
200070	misc
200079	neteller
200559	egold
200599	egold
200619	egold
200639	egold
200719	virtual_credit
200739	virtual_credit
200779	egold
201459	egold
201519	ebullion
201559	ebullion
201579	ebullion
201599	adjustment
\.


SET search_path = sequences, pg_catalog;

--
-- Name: account_serial; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('account_serial', (SELECT coalesce(max(id),19) FROM transaction.account), false);
SELECT pg_catalog.nextval('account_serial');


--
-- Name: bet_serial; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('bet_serial', greatest((SELECT coalesce(max(id),19) FROM bet.financial_market_bet_open),
                                                (SELECT coalesce(max(id),19) FROM bet.financial_market_bet)), false);
SELECT pg_catalog.nextval('bet_serial');


--
-- Name: global_serial; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('global_serial', greatest((SELECT coalesce(max(id),19) FROM bet.bet_dictionary),
                                                   (SELECT coalesce(max(id),19) FROM betonmarkets.client_affiliate_exposure),
                                                   (SELECT coalesce(max(id),19) FROM betonmarkets.client_authentication_document),
                                                   (SELECT coalesce(max(id),19) FROM betonmarkets.client_authentication_method),
                                                   (SELECT coalesce(max(id),19) FROM betonmarkets.client_promo_code),
                                                   (SELECT coalesce(max(id),19) FROM betonmarkets.client_status),
                                                   (SELECT coalesce(max(id),19) FROM betonmarkets.handoff_token),
                                                   (SELECT coalesce(max(id),19) FROM data_collection.exchange_rate)), true);
SELECT pg_catalog.nextval('global_serial');


--
-- Name: loginid_sequence_bft; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_bft', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='BFT'), false);
SELECT pg_catalog.nextval('loginid_sequence_bft');


--
-- Name: loginid_sequence_cbet; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_cbet', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='CBET'), false);
SELECT pg_catalog.nextval('loginid_sequence_cbet');


--
-- Name: loginid_sequence_cr; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_cr', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='CR'), false);
SELECT pg_catalog.nextval('loginid_sequence_cr');


--
-- Name: loginid_sequence_em; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_em', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='EM'), false);
SELECT pg_catalog.nextval('loginid_sequence_em');


--
-- Name: loginid_sequence_fotc; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_fotc', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='FOTC'), false);
SELECT pg_catalog.nextval('loginid_sequence_fotc');


--
-- Name: loginid_sequence_ftb; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_ftb', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='FTB'), false);
SELECT pg_catalog.nextval('loginid_sequence_ftb');


--
-- Name: loginid_sequence_mkt; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_mkt', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='MKT'), false);
SELECT pg_catalog.nextval('loginid_sequence_mkt');


--
-- Name: loginid_sequence_mlt; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_mlt', greatest((SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='MLT'), 19), false);
SELECT pg_catalog.nextval('loginid_sequence_mlt');


--
-- Name: loginid_sequence_mx; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_mx', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='MX'), false);
SELECT pg_catalog.nextval('loginid_sequence_mx');


--
-- Name: loginid_sequence_mxr; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_mxr', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='MXR'), false);
SELECT pg_catalog.nextval('loginid_sequence_mxr');


--
-- Name: loginid_sequence_nf; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_nf', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='NF'), false);
SELECT pg_catalog.nextval('loginid_sequence_nf');


--
-- Name: loginid_sequence_otc; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_otc', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='OTC'), false);
SELECT pg_catalog.nextval('loginid_sequence_otc');


--
-- Name: loginid_sequence_rcp; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_rcp', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='RCP'), false);
SELECT pg_catalog.nextval('loginid_sequence_rcp');


--
-- Name: loginid_sequence_test; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_test', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='TEST'), false);
SELECT pg_catalog.nextval('loginid_sequence_test');


--
-- Name: loginid_sequence_uk; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_uk', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='UK'), false);
SELECT pg_catalog.nextval('loginid_sequence_uk');


--
-- Name: loginid_sequence_vrt; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrt', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRT'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrt');


--
-- Name: loginid_sequence_vrtb; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtb', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTB'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrtb');


--
-- Name: loginid_sequence_vrtc; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtc', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTC'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrtc');


--
-- Name: loginid_sequence_vrte; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrte', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTE'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrte');


--
-- Name: loginid_sequence_vrtf; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtf', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTF'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrtf');


--
-- Name: loginid_sequence_vrtm; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtm', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTM'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrtm');


--
-- Name: loginid_sequence_vrtmkt; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtmkt', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTMKT'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrtmkt');


--
-- Name: loginid_sequence_vrtn; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtn', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTN'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrtn');


--
-- Name: loginid_sequence_vrto; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrto', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTO'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrto');


--
-- Name: loginid_sequence_vrtotc; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtotc', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTOTC'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrtotc');


--
-- Name: loginid_sequence_vrtp; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtp', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTP'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrtp');


--
-- Name: loginid_sequence_vrtr; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtr', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTR'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrtr');


--
-- Name: loginid_sequence_vrts; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrts', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTS'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrts');


--
-- Name: loginid_sequence_vrtu; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtu', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='VRTU'), false);
SELECT pg_catalog.nextval('loginid_sequence_vrtu');


--
-- Name: loginid_sequence_ws; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_ws', (SELECT coalesce(max(regexp_replace(loginid, '^\D+', '')::BIGINT),19) FROM betonmarkets.client WHERE broker_code='WS'), false);
SELECT pg_catalog.nextval('loginid_sequence_ws');


--
-- Name: loginid_serial; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_serial', 219, false);


--
-- Name: payment_serial; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('payment_serial', (SELECT coalesce(max(id),19) FROM payment.payment), false);
SELECT pg_catalog.nextval('payment_serial');

--
--

SELECT pg_catalog.setval('serials_configurations_id_seq', (SELECT coalesce(max(id),19) FROM sequences.serials_configurations), false);
SELECT pg_catalog.nextval('serials_configurations_id_seq');

-- let's not play around trying to be just a little ahead
SELECT pg_catalog.setval('transaction_serial', (SELECT coalesce(max(id),19) FROM transaction.transaction), false);
SELECT pg_catalog.nextval('transaction_serial');


