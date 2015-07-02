--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;


SET search_path = audit, pg_catalog;
--
-- Data for Name: db_activity; Type: TABLE DATA; Schema: audit; Owner: postgres
--

INSERT INTO db_activity VALUES ('replicator', '2014-02-10 10:05:32.495614', '10 years');
INSERT INTO db_activity VALUES ('others', '2014-02-10 10:05:32.495614', '10 years');



SET search_path = betonmarkets, pg_catalog;

INSERT INTO broker_code VALUES ('CBET');
INSERT INTO broker_code VALUES ('VRT');
INSERT INTO broker_code VALUES ('MLT');
INSERT INTO broker_code VALUES ('MF');
INSERT INTO broker_code VALUES ('NF');
INSERT INTO broker_code VALUES ('VRTM');
INSERT INTO broker_code VALUES ('MX');
INSERT INTO broker_code VALUES ('MXR');
INSERT INTO broker_code VALUES ('VRTU');
INSERT INTO broker_code VALUES ('FOG');
INSERT INTO broker_code VALUES ('UK');
INSERT INTO broker_code VALUES ('TEST');
INSERT INTO broker_code VALUES ('FTB');
INSERT INTO broker_code VALUES ('VRTF');
INSERT INTO broker_code VALUES ('CR');
INSERT INTO broker_code VALUES ('VRTC');
INSERT INTO broker_code VALUES ('VRTN');
INSERT INTO broker_code VALUES ('VRTR');
INSERT INTO broker_code VALUES ('VRTS');
INSERT INTO broker_code VALUES ('WS');
INSERT INTO broker_code VALUES ('RCP');
INSERT INTO broker_code VALUES ('VRTP');
INSERT INTO broker_code VALUES ('FOTC');
INSERT INTO broker_code VALUES ('VRTO');
INSERT INTO broker_code VALUES ('EM');
INSERT INTO broker_code VALUES ('VRTE');
INSERT INTO broker_code VALUES ('BFT');
INSERT INTO broker_code VALUES ('VRTB');

--
-- Data for Name: client; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

INSERT INTO client VALUES ('MLT0012', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Bond Lim', 'bond@regentmarkets.com', true, 'MLT', 'au', 'au', 'Mr', 'address', '', 'tiwn', '', '12341', '+621111111111', '2009-02-23 07:33:00', '23-Feb-09 07h33GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4', '', 'm', '', '1988-09-12', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('MLT0013', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'ivan@regentmarkets.com', true, 'MLT', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '12345', '+6111111111', '2009-08-13 09:34:00', '13-Aug-09 09h34GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', '', '', '', 'm', '', '1932-09-07', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('MLT0014', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'bond@regentmarkets.com', true, 'MLT', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-08-13 09:43:00', '13-Aug-09 09h43GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', '', '', '', 'm', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('MLT0015', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'bond@regentmarkets.com', true, 'MLT', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-08-31 08:00:00', '31-Aug-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', '', '', '', 'm', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('MLT0016', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'bond@regentmarkets.com', true, 'MLT', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', '', '', '', 'm', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('MX0012', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Bond Lim', 'bond@regentmarkets.com', true, 'MX', 'au', 'au', 'Mr', 'address', '', 'tiwn', '', '12341', '+621111111111', '2009-02-23 07:33:00', '23-Feb-09 07h33GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4', '', 'm', '', '1988-09-12', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('MX0013', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'ivan@regentmarkets.com', true, 'MX', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '12345', '+6111111111', '2009-08-13 09:34:00', '13-Aug-09 09h34GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4', '', 'm', '', '1932-09-07', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('MX0014', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'bond@regentmarkets.com', true, 'MX', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-08-13 09:43:00', '13-Aug-09 09h43GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'm', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('MX0015', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'bond@regentmarkets.com', true, 'MX', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-08-31 08:00:00', '31-Aug-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'm', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('MX0016', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'bond@regentmarkets.com', true, 'MX', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'm', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('MLT0017', '960f984285701c6d8dba5dc71c35c55c0397ff276b06423146dde88741ddf1af', 'Pornchai', 'Chuengsawat', 'felix@regentmarkets.com', true, 'MLT', 'th', 'th', 'Mr', '97/13 Tararom vill., Sukhapiban 3 RD., Sapansoong,', '', 'Bangkok', '', '10240', '123456789', NULL, '25-Dec-07 13h33GMT 124.120.26.75 Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1; SV1; .NET CLR 1.1.4322; .NET CLR 2.0.50727) LANG=EN SKIN=', 'What is your pet', '::ecp::52616e646f6d49563336336867667479e29117e32952b1c56491a644700d6963', '', 'm', '', '1974-05-15', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0001', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'CR', 'gb', 'gb', 'Mr', 'test', 'test  ', 'test', '', 'te12st', '44999999999', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', '', '1982-07-17', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0002', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'CR', 'gb', 'gb', 'Mr', 'test1', 'test2  ', 'test', '', 'te12st', '44999999999', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', '', '1982-07-17', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0003', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'CR', 'gb', 'gb', 'Mr', 'test1', 'test2  ', 'test', '', 'te12st', '44999999999', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', '', '1982-07-17', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0004', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'CR', 'gb', 'gb', 'Mr', 'test1', 'test2  ', 'test', '', 'te12st', '44999999999', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', '', '1982-07-17', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0005', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'CR', 'gb', 'gb', 'Mr', 'test1', 'test2  ', 'test', '', 'te12st', '44999999999', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', '', '1982-07-17', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0006', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'CR', 'gb', 'gb', 'Mr', 'test1', 'test2  ', 'test', '', 'te12st', '44999999999', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', '', '1982-07-17', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0007', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'CR', 'gb', 'gb', 'Mr', 'test1', 'test2  ', 'test', '', 'te12st', '44999999999', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', '', '1982-07-17', 'notarised', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0008', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'CR', 'gb', 'gb', 'Mr', 'test1', 'test2  ', 'test', '', 'te12st', '44999999999', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', '', '1982-07-17', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0009', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'CR', 'de', 'gb', 'Mr', 'test1', 'test2  ', 'test', '', 'te12st', '00869145685791', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', 'ILOVEBUGS', '1982-07-17', 'notarised', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0010', '$1$s5fRSVzb$E9UlOOXKoBWJApUuxjdas.', 'mohammad', 'shamsi', 'fuguo@regentmarkets.com', true, 'CR', 'ir', 'ir', 'Mr', 'somewhere', 'somewhere  ', 'Tehran', '', '121212', '+9822424242', '2008-12-17 02:25:00', '17-Dec-08 02h25GMT 192.168.12.51 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9b5) Gecko/2008052519 CentOS/3.0b5-0.beta5.6.el5.centos Firefox/3.0b5 LANG=EN SKIN=', 'Memorable town city', '::ecp::52616e646f6d495633363368676674799a9ef5e1e303e68c', '', 'm', '', '1980-03-12', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0011', '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92', 'Amy', 'mimi', 'shuwnyuan@yahoo.com', true, 'CR', 'au', 'au', 'Ms', '53, Jln Address 1', 'Jln Address 2', 'Segamat', '', '85010', '069782001', '2009-02-20 06:08:00', '16-Jul-09 08h18GMT 192.168.12.62 Mozilla 5.0 (X11; U; Linux i686; en-US; rv:1.8.1.14) Gecko 20080404 Firefox 2.0.0.14 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d49563336336867667479f75f67cfc8179b31', '192.168.0.1', 'f', '', '1980-01-01', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0012', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Bond Lim', 'bond@regentmarkets.com', true, 'CR', 'au', 'au', 'Mr', 'address', '', 'tiwn', '', '12341', '+621111111111', '2009-02-23 07:33:00', '23-Feb-09 07h33GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4', '', 'm', '', '1988-09-12', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0013', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'ivan@regentmarkets.com', true, 'CR', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '12345', '+6111111111', '2009-08-13 09:34:00', '13-Aug-09 09h34GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4', '', 'm', '', '1932-09-07', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0014', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'bond@regentmarkets.com', true, 'CR', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-08-13 09:43:00', '13-Aug-09 09h43GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'm', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0015', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Nick', 'Marden', 'nick@regentmarkets.com', true, 'CR', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-08-31 08:00:00', '31-Aug-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'm', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0016', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'bond@regentmarkets.com', true, 'CR', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'm', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0017', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'bond@regentmarkets.com', true, 'CR', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '12345', '+611111111111', '2009-08-19 09:21:00', '19-Aug-09 09h21GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.1.2) Gecko/20090729 Firefox/3.5.2 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d49563336336867667479aaa24e146dc593e4', '', 'm', '', '1922-02-01', 'notarised', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0020', '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92', 'shuwnyuan', 'tee', 'shuwnyuan@regentmarkets.com', true, 'CR', 'au', 'my', 'Ms', '53, Jln Address 1', 'Jln Address 2 Jln Address 3 Jln Address 4', 'Segamat', '', '85010', '069782001', '2009-02-20 06:08:00', '16-Jul-09 08h18GMT 192.168.12.62 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.8.1.14) Gecko/20080404 Firefox/2.0.0.14 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d49563336336867667479f75f67cfc8179b31', '192.168.0.1', 'f', '', '1980-01-01', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0021', '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92', 'shuwnyuan', 'tee', 'shuwnyuan@regentmarkets.com', true, 'CR', 'au', 'my', 'Ms', '53, Jln Address 1', 'Jln Address 2 Jln Address 3 Jln Address 4', 'Segamat', '', '85010', '069782001', '2009-02-20 06:08:00', '16-Jul-09 08h18GMT 192.168.12.62 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.8.1.14) Gecko/20080404 Firefox/2.0.0.14 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d49563336336867667479f75f67cfc8179b31', '192.168.0.1', 'f', '', '1980-01-01', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0022', '48elKjgSSiaeD5v233716ab5', '†•…‰™œŠŸž€ΑΒΓΔΩαβγδωАБВГДабвгд∀∂∈ℝ∧∪≡∞↑↗↨↻⇣┐┼╔╘░►☺', '♀ﬁ�⑀₂ἠḂӥẄɐː⍎אԱა Καλημέρα κόσμε, コンニチハ', 'TanChongGee@yahoo.com', true, 'CR', 'gb', '', 'Mr', '', '', '', '', '', '', NULL, '28-Sep-07 02h09GMT 192.168.12.59 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.8.1.6) Gecko/20070813 Fedora/2.0.0.6-3.fc8 Firefox/2.0.0.6 LANG=EN SKIN=', '', '', '', 'm', '', '1975-02-16', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0023', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'shuwnyuan', 'tee', 'sy@regentmarkets.com', true, 'CR', 'au', 'au', 'Ms', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'f', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0024', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'shuwnyuan', 'tee', 'sy@regentmarkets.com', true, 'CR', 'au', 'au', 'Ms', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'f', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0025', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'shuwnyuan', 'tee', 'sy@regentmarkets.com', true, 'CR', 'au', 'au', 'Ms', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'f', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0026', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'bond@regentmarkets.com', true, 'CR', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'm', '', '1953-08-06', 'yes', '', 'XXXXX', false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0027', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'Bond', 'Lim', 'bond@regentmarkets.com', true, 'CR', 'au', 'au', 'Mr', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'm', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0028', '6ca13d52ca70c883e0f0bb101e425a89e8624de51db2d2392593af6a84118090', 'Polar', 'Bear', 'sokting@regentmarkets.com', true, 'CR', 'aq', 'aq', 'Mr', 'Igloo 1', 'Polar street  ', 'Bearcity', '', '11111', '+6712345678', '2009-11-18 08:00:00', '18-Nov-09 02h50GMT 192.168.12.43 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9b5) Gecko/2008052519 CentOS/3.0b5-0.beta5.6.el5.centos Firefox/3.0b5 LANG=EN SKIN=', 'Favourite dish', '::ecp::52616e646f6d49563336336867667479058d7cb3c47cb130', '', 'm', '', '1919-01-01', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0029', '6ca13d52ca70c883e0f0bb101e425a89e8624de51db2d2392593af6a84118090', 'Polar', 'Bear', 'sokting@regentmarkets.com', true, 'CR', 'aq', 'aq', 'Mr', 'Igloo 1', 'Polar street  ', 'Bearcity', '', '11111', '+6712345678', '2009-11-18 08:00:00', '18-Nov-09 02h50GMT 192.168.12.43 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9b5) Gecko/2008052519 CentOS/3.0b5-0.beta5.6.el5.centos Firefox/3.0b5 LANG=EN SKIN=', 'Favourite dish', '::ecp::52616e646f6d49563336336867667479058d7cb3c47cb130', '', 'm', '', '1919-01-01', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0030', '6ca13d52ca70c883e0f0bb101e425a89e8624de51db2d2392593af6a84118090', 'Polar', 'Bear', 'sokting@regentmarkets.com', true, 'CR', 'aq', 'aq', 'Mr', 'Igloo 1', 'Polar street  ', 'Bearcity', '', '11111', '+6712345678', '2009-11-18 08:00:00', '18-Nov-09 02h50GMT 192.168.12.43 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9b5) Gecko/2008052519 CentOS/3.0b5-0.beta5.6.el5.centos Firefox/3.0b5 LANG=EN SKIN=', 'Favourite dish', '::ecp::52616e646f6d49563336336867667479058d7cb3c47cb130', '', 'm', '', '1919-01-01', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0031', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'CR', 'de', 'gb', 'Mr', 'test1', 'test2  ', 'test', '', 'te12st', '00869145685791', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', 'ILOVEBUGS', '1982-07-17', 'notarised', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0032', '8d969eef6ecad3c29a3a629280e686cf0c3f5d5a86aff3ca12020c923adc6c92', 'tee', 'shuwnyuan', 'shuwnyuan@regentmarkets.com', true, 'CR', 'au', 'au', 'Ms', 'ADDR 1', 'ADDR 2', 'Segamat', '', '85010', '+60123456789', '2010-05-12 06:40:11', '12-May-10 06:40:11GMT 127.0.0.1  LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d49563336336867667479f75f67cfc8179b31', '', 'f', '', '1980-01-01', 'no', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0099', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'shuwnyuan', 'tee', 'sy@regentmarkets.com', true, 'CR', 'au', 'au', 'Ms', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'f', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR0100', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'shuwnyuan', 'tee', 'sy@regentmarkets.com', true, 'CR', 'au', 'au', 'Ms', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'f', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('UK1001', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'UK', 'de', 'gb', 'Mr', 'test1', 'test2  ', 'test', '', 'te12st', '00869145685791', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', 'ILOVEBUGS', '1982-07-17', 'notarised', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('VRTC1001', 'ff3LtC2i6ikST/IU5e7e0011', 'Calum', 'Halcrow', 'dummy@regentmarkets.com', true, 'VRTC', 'de', 'gb', 'Mr', 'test1', 'test2  ', 'test', '', 'te12st', '00869145685791', NULL, '8-Feb-07 08h19GMT 127.0.0.1  LANG=EN', 'Favourite dish', '::ecp::52616e646f6d495633363368676674796c67c6f4ecf8c795', '', 'm', 'ILOVEBUGS', '1982-07-17', 'notarised', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('MX1001', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'shuwnyuan', 'tee', 'sy@regentmarkets.com', true, 'MX', 'au', 'au', 'Ms', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'f', '', '1953-08-06', 'yes', '', 'XXXX', false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR2002', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'shuwnyuan', 'tee', 'sy@regentmarkets.com', true, 'CR', 'au', 'au', 'Ms', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'f', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR3003', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'shuwnyuan', 'tee', 'sy@regentmarkets.com', true, 'CR', 'au', 'au', 'Ms', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'f', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);
INSERT INTO client VALUES ('CR9999', 'ed0e7631adc703166cbd6494cc92f1775a19af7c49088e876cc1c53a05f15544', 'shuwnyuan', 'tee', 'sy@regentmarkets.com', true, 'CR', 'au', 'au', 'Ms', 'test', 'test  ', 'test', '', '11111', '+61111231411', '2009-07-31 08:00:00', '31-Jul-09 08h00GMT 192.168.12.39 Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.0.6) Gecko/2009020414 CentOS/3.0.6-1.el5.centos Firefox/3.0.6 LANG=EN SKIN=', 'Mother''s maiden name', '::ecp::52616e646f6d4956333633686766747950fe7262c4589c41', '', 'f', '', '1953-08-06', 'yes', '', NULL, false, false, NULL, NULL, NULL, NULL, NULL, true);


SET search_path = transaction, pg_catalog;

--
-- Data for Name: account; Type: TABLE DATA; Schema: transaction; Owner: postgres
--
INSERT INTO account VALUES (1201, 'CR0011', 'USD', 0.0000, TRUE, NULL);
INSERT INTO account VALUES (1203, 'CR9999', 'USD', 0.0000, TRUE, NULL);
INSERT INTO account VALUES (200419, 'CR0012', 'USD', 0.0000, TRUE, NULL);
INSERT INTO account VALUES (200259, 'CR0029', 'USD', 0.0000, TRUE, '2014-02-11 07:58:35.97623');
INSERT INTO account VALUES (200359, 'CR0021', 'USD', 1000.0000, TRUE, '2014-02-11 07:58:36.429121');
INSERT INTO account VALUES (200539, 'MX0015', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.434709');
INSERT INTO account VALUES (200039, 'MX1001', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:35.8493');
INSERT INTO account VALUES (200519, 'MX0016', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.451031');
INSERT INTO account VALUES (200279, 'CR0028', 'USD', 0.0000, TRUE, '2014-02-11 07:58:36.00272');
INSERT INTO account VALUES (200319, 'CR0026', 'USD', 0.0000, TRUE, '2014-02-11 07:58:36.302325');
INSERT INTO account VALUES (200299, 'CR0027', 'USD', 0.0000, TRUE, '2014-02-11 07:58:36.007895');
INSERT INTO account VALUES (200399, 'CR0013', 'USD', 0.0000, TRUE, '2014-02-11 07:58:36.310453');
INSERT INTO account VALUES (200439, 'CR0009', 'USD', 0.0000, TRUE, '2014-02-11 07:58:36.313095');
INSERT INTO account VALUES (200099, 'MX0013', 'USD', 0.0000, TRUE, '2014-02-11 07:58:35.878726');
INSERT INTO account VALUES (200599, 'MLT0015', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.458924');
INSERT INTO account VALUES (200559, 'MX0014', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.464309');
INSERT INTO account VALUES (200579, 'MLT0016', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.467028');
INSERT INTO account VALUES (200859, 'MLT0017', 'EUR', 0.0000, TRUE, '2014-02-11 07:58:36.948185');
INSERT INTO account VALUES (200459, 'CR0008', 'USD', 0.0000, TRUE, '2014-02-11 07:58:36.328897');
INSERT INTO account VALUES (200499, 'CR0005', 'USD', 0.0000, TRUE, '2014-02-11 07:58:36.339299');
INSERT INTO account VALUES (200199, 'MLT0013', 'USD', 0.0000, TRUE, '2014-02-11 07:58:35.913191');
INSERT INTO account VALUES (1202, 'CR0010', 'EUR', 0.0000, TRUE, '2014-02-11 07:58:37.252266');
INSERT INTO account VALUES (200619, 'MLT0014', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.490798');
INSERT INTO account VALUES (200339, 'CR0025', 'USD', 0.0000, TRUE, '2014-02-11 07:58:36.216653');
INSERT INTO account VALUES (200699, 'CR0023', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.656067');
INSERT INTO account VALUES (200219, 'CR0031', 'USD', 0.0000, TRUE, '2014-02-11 07:58:35.960573');
INSERT INTO account VALUES (200779, 'CR0015', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.669816');
INSERT INTO account VALUES (200379, 'CR0016', 'USD', 0.0000, TRUE, '2014-02-11 07:58:36.260078');
INSERT INTO account VALUES (200479, 'CR0006', 'USD', 0.0000, TRUE, '2014-02-11 07:58:36.262706');
INSERT INTO account VALUES (200799, 'CR0014', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.728353');
INSERT INTO account VALUES (200919, 'MX0012', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:37.453748');
INSERT INTO account VALUES (200939, 'MLT0012', 'AUD', 0.0000, TRUE, '2014-02-11 07:58:37.456413');
INSERT INTO account VALUES (200679, 'CR0024', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.570623');
INSERT INTO account VALUES (200739, 'CR0017', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.575938');
INSERT INTO account VALUES (201039, 'CR0099', 'USD', 0.0000, TRUE, '2014-02-11 07:58:37.50219');
INSERT INTO account VALUES (200639, 'CR0030', 'GBP', 0.0000, TRUE, '2014-02-11 07:58:36.92148');
INSERT INTO account VALUES (201079, 'CR2002', 'USD', 0.0000, TRUE, '2014-02-11 07:58:37.504822');



SET search_path = bet, pg_catalog;

--
-- Data for Name: financial_market_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

INSERT INTO financial_market_bet VALUES (200039, '2011-03-09 07:25:00', 200039, 'R_50', 10, 5.2, NULL, '2011-03-09 06:25:27', '2011-03-09 06:29:27', '2011-03-09 06:29:27', false, false, false, 'higher_lower_bet', 'FLASHU', ' vega[-0.00003] atmf_fct[0.70000] div[0.00000] recalc[5.20000] int[0.00000] theta[0.49525] iv[0.50000] emp[4.79000] fwdst_fct[1.00000] win[10.00000] trade[5.20000] dscrt_fct[1.00000] spot[1700.24600] gamma[-0.09541] delta[28.92262] theo[5.00000] base_spread[0.04000] ia_fct[1.00000] news_fct[1.00000]', 'FLASHU_R_50_10_1299651927_1299652167_S0P_0', NULL);
INSERT INTO financial_market_bet VALUES (200059, '2011-03-09 07:25:00', 200039, 'frxUSDJPY', 100, 53.75, NULL, '2011-03-09 06:25:52', '2011-03-14 23:59:59', '2011-03-14 23:59:59', true, false, false, 'higher_lower_bet', 'CALL', ' vega[-0.00559] atmf_fct[0.74662] div[0.00252] recalc[53.75000] int[0.00107] theta[0.06065] iv[0.10700] emp[48.79000] fwdst_fct[1.00000] win[100.00000] trade[53.75000] dscrt_fct[1.00000] spot[82.88000] gamma[-0.20229] delta[29.63453] theo[50.02000] base_spread[0.10000] ia_fct[1.00000] news_fct[1.00000]', 'CALL_FRXUSDJPY_100_1299651952_14_MAR_11_828700_0', NULL);
INSERT INTO financial_market_bet VALUES (202359, '2009-07-31 08:21:00', 200519, 'frxXAUUSD', 10000, 3140, 0, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202439, '2009-08-13 12:00:00', 200619, 'FTSE', 500, 376, NULL, '2009-08-13 00:00:00', '2006-01-27 16:30:00', '2006-01-27 23:59:59', true, true, false, 'higher_lower_bet', 'PUT', 'theo=326.5257 trade=376 recalc=378.8 win=500 TYPE=PUT u=FTSE S=5701.7 r=0.0464 q=0.0347 t=0.04122 H=5750 L=0 iv=0.1013 delta=-0.178923910279832 vega=-0.0136731597908051 theta=0.00495105459849295 gamma=-0.0327372153570317 intradaytime=0.529411764705882 ATTRAC:-4', 'PUT_FTSE_500_13_AUG_09_27_JAN_06_5750_0', NULL);
INSERT INTO financial_market_bet VALUES (200139, '2009-08-14 07:19:00', 200099, 'frxGBPJPY', 30, 15.04, 0, '2009-08-14 07:19:52', '2009-08-14 07:20:22', '2009-08-14 07:20:22', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 intradaytime= theo=1', 'FLASHU_FRXGBPJPY_30_14_AUG_09_S30_07H1952', NULL);
INSERT INTO financial_market_bet VALUES (200379, '2009-08-14 07:19:00', 200199, 'frxGBPJPY', 30, 15.04, 0, '2009-08-14 07:19:52', '2009-08-14 07:20:22', '2009-08-14 07:20:22', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 intradaytime= theo=1', 'FLASHU_FRXGBPJPY_30_14_AUG_09_S30_07H1952', NULL);
INSERT INTO financial_market_bet VALUES (201559, '2005-09-21 06:28:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.607,111.615,111.591,111.607,111.598,111.599,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201579, '2005-09-21 06:28:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.587,111.583,111.601,111.607,111.592,111.607,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (200439, '2009-11-18 08:46:00', 200279, 'frxEURUSD', 10, 30, 0, '2009-10-20 00:00:00', '2009-10-21 00:00:00', '2009-10-21 23:59:59', false, true, true, 'legacy_bet', 'DOUBLEONETOUCH', 'theo=5.97 trade=7.26 recalc=7.24 win=10 [MarkupEngine::Hedge] S=0.9126 r=0.0113 q=0.01326 t=0.00447761288685946 H=0.9163 L=0.9107 iv=0.191 (0.470343699687832,0.724264579356303,0.597304139522068,buy,FM=0) delta=-0.153374253450337 vega=0.0368378823608042 theta=-1.12652750894949 gamma=2.25702621452758 theo=5.97 spot_time=1256028394 ', 'DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107', NULL);
INSERT INTO financial_market_bet VALUES (200499, '2005-09-21 06:16:00', 200359, 'frxUSDJPY', 10, 5, 9.5, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.658,111.656,111.665,111.67,111.662,111.66,', 'RUNBET_DOUBLEUP_USD100_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (200599, '2005-09-21 06:16:00', 200359, 'frxUSDJPY', 10, 5, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.667,111.669,111.661,111.667,111.664,111.667,', 'RUNBET_DOUBLEUP_USD100_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (200639, '2005-09-21 06:16:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.669,111.656,111.676,111.66,111.658,111.664,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (200739, '2005-09-21 06:17:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.677,111.689,111.695,111.689,111.67,111.681,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (200779, '2005-09-21 06:17:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.681,111.685,111.709,111.676,111.67,111.671,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (200799, '2005-09-21 06:18:00', 200359, 'frxUSDJPY', 40, 20, 38, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.686,111.691,111.703,111.672,111.685,111.673,', 'RUNBET_DOUBLEDOWN_USD400_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (200819, '2005-09-21 06:18:00', 200359, 'frxUSDJPY', 10, 5, 9.5, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.691,111.68,111.681,111.703,111.69,111.686,', 'RUNBET_DOUBLEDOWN_USD100_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (200839, '2005-09-21 06:19:00', 200359, 'frxUSDJPY', 10, 5, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.682,111.684,111.67,111.675,111.672,111.689,', 'RUNBET_DOUBLEDOWN_USD100_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (200879, '2005-09-21 06:20:00', 200359, 'frxUSDJPY', 30, 15, 28.5, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.68,111.688,111.697,111.692,111.691,111.684,', 'RUNBET_DOUBLEUP_USD300_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (200939, '2005-09-21 06:20:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.686,111.685,111.686,111.698,111.68,111.685,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (200999, '2005-09-21 06:21:00', 200359, 'frxUSDJPY', 40, 20, 38, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.675,111.661,111.671,111.677,111.67,111.671,', 'RUNBET_DOUBLEDOWN_USD400_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201059, '2005-09-21 06:21:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.667,111.674,111.665,111.666,111.662,111.659,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201099, '2005-09-21 06:22:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.65,111.679,111.669,111.674,111.663,111.662,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201119, '2005-09-21 06:22:00', 200359, 'frxUSDJPY', 40, 20, 38, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.662,111.675,111.67,111.672,111.66,111.673,', 'RUNBET_DOUBLEUP_USD400_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201139, '2005-09-21 06:22:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.666,111.671,111.679,111.677,111.697,111.678,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201199, '2005-09-21 06:23:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.662,111.676,111.677,111.675,111.677,111.676,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201259, '2005-09-21 06:24:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.672,111.666,111.668,111.66,111.669,111.679,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201299, '2005-09-21 06:24:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.671,111.674,111.688,111.68,111.685,111.676,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201339, '2005-09-21 06:24:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.679,111.662,111.66,111.676,111.683,111.674,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201379, '2005-09-21 06:25:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.673,111.677,111.675,111.661,111.66,111.672,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201419, '2005-09-21 06:25:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.669,111.664,111.655,111.657,111.654,111.65,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201439, '2005-09-21 06:26:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.652,111.654,111.665,111.664,111.663,111.669,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201459, '2005-09-21 06:26:00', 200359, 'frxUSDJPY', 40, 20, 38, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.664,111.656,111.667,111.661,111.66,111.689,', 'RUNBET_DOUBLEUP_USD400_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201479, '2005-09-21 06:27:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.681,111.673,111.664,111.666,111.654,111.641,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201499, '2005-09-21 06:27:00', 200359, 'frxUSDJPY', 40, 20, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.659,111.643,111.654,111.646,111.642,111.659,', 'RUNBET_DOUBLEDOWN_USD400_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201519, '2005-09-21 06:27:00', 200359, 'frxUSDJPY', 80, 40, 76, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.643,111.632,111.635,111.632,111.638,111.647,', 'RUNBET_DOUBLEUP_USD800_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201539, '2005-09-21 06:28:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.629,111.623,111.644,111.618,111.611,111.618,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201599, '2005-09-21 06:29:00', 200359, 'frxUSDJPY', 40, 20, 38, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.564,111.574,111.576,111.57,111.574,111.572,', 'RUNBET_DOUBLEUP_USD400_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201619, '2005-09-21 06:29:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.576,111.588,111.578,111.568,111.562,111.581,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201639, '2005-09-21 06:29:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.586,111.592,111.598,111.584,111.583,111.585,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201659, '2005-09-21 06:30:00', 200359, 'frxUSDJPY', 40, 20, 38, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.577,111.584,111.583,111.575,111.571,111.569,', 'RUNBET_DOUBLEDOWN_USD400_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201679, '2005-09-21 06:32:00', 200359, 'frxUSDJPY', 50, 25, NULL, '2005-09-21 06:50:00', '2005-09-21 07:00:00', '2005-09-21 07:00:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXUSDJPY_50_21_SEP_05_6H5_7', NULL);
INSERT INTO financial_market_bet VALUES (201699, '2005-09-21 06:33:00', 200359, 'frxUSDJPY', 40, 20, NULL, '2005-09-21 06:50:00', '2005-09-21 07:10:00', '2005-09-21 07:10:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXUSDJPY_40_21_SEP_05_6H5_7H1', NULL);
INSERT INTO financial_market_bet VALUES (201719, '2005-09-21 06:34:00', 200359, 'frxUSDJPY', 40, 20, NULL, '2005-09-21 06:50:00', '2005-09-21 07:20:00', '2005-09-21 07:20:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXUSDJPY_40_21_SEP_05_6H5_7H2', NULL);
INSERT INTO financial_market_bet VALUES (201739, '2005-09-21 06:34:00', 200359, 'frxUSDJPY', 50, 25, NULL, '2005-09-21 06:50:00', '2005-09-21 07:30:00', '2005-09-21 07:30:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXUSDJPY_50_21_SEP_05_6H5_7H3', NULL);
INSERT INTO financial_market_bet VALUES (201759, '2005-09-21 06:35:00', 200359, 'frxUSDJPY', 50, 25, NULL, '2005-09-21 06:50:00', '2005-09-21 07:50:00', '2005-09-21 07:50:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXUSDJPY_50_21_SEP_05_6H5_7H5', NULL);
INSERT INTO financial_market_bet VALUES (201779, '2005-09-21 06:36:00', 200359, 'frxUSDJPY', 50, 25, NULL, '2005-09-21 07:00:00', '2005-09-21 07:10:00', '2005-09-21 07:10:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXUSDJPY_50_21_SEP_05_7_7H1', NULL);
INSERT INTO financial_market_bet VALUES (201799, '2005-09-21 06:37:00', 200359, 'frxUSDJPY', 40, 20, NULL, '2005-09-21 07:10:00', '2005-09-21 07:20:00', '2005-09-21 07:20:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXUSDJPY_40_21_SEP_05_7H1_7H2', NULL);
INSERT INTO financial_market_bet VALUES (201819, '2005-09-21 06:37:00', 200359, 'frxUSDJPY', 50, 25, NULL, '2005-09-21 07:20:00', '2005-09-21 07:30:00', '2005-09-21 07:30:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXUSDJPY_50_21_SEP_05_7H2_7H3', NULL);
INSERT INTO financial_market_bet VALUES (200459, '2009-10-20 08:46:00', 200299, 'frxEURUSD', 10, 300, 0, '2009-10-20 00:00:00', '2009-10-21 00:00:00', '2009-10-21 23:59:59', false, true, true, 'legacy_bet', 'DOUBLEONETOUCH', 'theo=5.97 trade=7.26 recalc=7.24 win=10 [MarkupEngine::Hedge] S=0.9126 r=0.0113 q=0.01326 t=0.00447761288685946 H=0.9163 L=0.9107 iv=0.191 (0.470343699687832,0.724264579356303,0.597304139522068,buy,FM=0) delta=-0.153374253450337 vega=0.0368378823608042 theta=-1.12652750894949 gamma=2.25702621452758 theo=5.97 spot_time=1256028394 ', 'DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107', NULL);
INSERT INTO financial_market_bet VALUES (202379, '2009-08-13 12:00:00', 200559, 'FTSE', 500, 376, NULL, '2009-08-13 00:00:00', '2006-01-27 16:30:00', '2006-01-27 23:59:59', true, true, false, 'higher_lower_bet', 'PUT', 'theo=326.5257 trade=376 recalc=378.8 win=500 TYPE=PUT u=FTSE S=5701.7 r=0.0464 q=0.0347 t=0.04122 H=5750 L=0 iv=0.1013 delta=-0.178923910279832 vega=-0.0136731597908051 theta=0.00495105459849295 gamma=-0.0327372153570317 intradaytime=0.529411764705882 ATTRAC:-4', 'PUT_FTSE_500_13_AUG_09_27_JAN_06_5750_0', NULL);
INSERT INTO financial_market_bet VALUES (202419, '2009-08-13 12:03:00', 200559, 'FCHI', 500, 396.9, NULL, '2009-08-13 00:00:00', '2006-01-27 16:30:00', '2006-01-27 23:59:59', true, true, false, 'higher_lower_bet', 'PUT', 'theo=348.2965 trade=396.9 recalc=396.9 win=500 TYPE=PUT u=FCHI S=4842.3 r=0.02335 q=0.0234 t=0.041204 H=4900 L=0 iv=0.1156 delta=-0.148613257357714 vega=-0.0148746544665071 theta=0.00602276790084144 gamma=-0.0312186193847232 intradaytime=0.523529411764706 ATTRAC:-4', 'PUT_FCHI_500_13_AUG_09_27_JAN_06_4900_0', NULL);
INSERT INTO financial_market_bet VALUES (200659, '2007-04-16 02:01:00', 200339, 'frxEURUSD', 10, 5, 10, '2007-04-16 02:20:00', '2007-04-16 02:30:00', '2007-04-16 02:30:00', false, true, true, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXEURUSD_10_16_APR_07_2H2_2H3', NULL);
INSERT INTO financial_market_bet VALUES (200579, '2007-04-16 01:48:00', 200339, 'frxGBPJPY', 10, 5, 10, '2007-04-16 05:50:00', '2007-04-16 06:00:00', '2007-04-16 06:00:00', false, true, true, 'higher_lower_bet', 'INTRADD', NULL, 'INTRADD_FRXGBPJPY_10_16_APR_07_5H5_6', NULL);
INSERT INTO financial_market_bet VALUES (200519, '2007-04-16 01:43:00', 200339, 'frxEURUSD', 10, 5, 10, '2007-04-16 21:20:00', '2007-04-16 21:30:00', '2007-04-16 21:30:00', false, true, true, 'higher_lower_bet', 'INTRADD', NULL, 'INTRADD_FRXEURUSD_10_16_APR_07_21H2_21H3', NULL);
INSERT INTO financial_market_bet VALUES (202539, '2009-09-29 05:53:00', 200639, 'frxEURUSD', 15.86, 5, 0, '2009-09-29 05:53:52', '2009-09-29 05:55:00', '2009-09-29 05:55:00', false, true, true, 'higher_lower_bet', 'CALL', 'type=bull currency=GBP stake=5 profit=10.86 underlying=frxEURUSD duration=300 purchase_time=1254203632 start_time=1254203400 bull_bear_boundary_spot=1.4637 is_sold=0 sold_price=0 sold_time=0', 'CALL_FRXEURUSD_15.86_1254203632_1254203700_14637_0', NULL);
INSERT INTO financial_market_bet VALUES (202599, '2009-09-30 10:20:00', 200639, 'frxAUDJPY', 10, 5.21, 0, '2009-09-30 10:20:08', '2009-09-30 10:20:38', '2009-09-30 10:20:38', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=5 trade=5.21 recalc=5.21 win=10 (0.5,buy) delta=0.01 vega=0 theta=0 gamma=0 intradaytime= theo=5 spot_time=1254306008 ', 'FLASHU_FRXAUDJPY_10_30_SEP_09_S30_10H2008', NULL);
INSERT INTO financial_market_bet VALUES (202679, '2009-07-31 15:21:00', 200699, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202699, '2009-10-07 04:00:00', 200639, 'frxAUDJPY', 10, 6.13, 10, '2009-10-07 04:00:43', '2009-10-07 04:05:43', '2009-10-07 04:05:43', false, true, true, 'higher_lower_bet', 'CALL', 'theo=5.63 trade=6.13 recalc=6.13 win=10 [MarkupEngine::Hedge] S=78.96 r=0.00568 q=0.05213 t=9.51293759512938e-06 H=78.96 L=0 iv=0.1383 ATTRAC=0 (0.513404517767627,0.613404517767627,0.563404517767627,buy,FM=0) delta=93.5255346357448 vega=3.28180629702132e-05 theta=0.717706140009266 gamma=12.8814502847153 intradaytime= theo=5.63 spot_time=1254888043 ', 'CALL_FRXAUDJPY_10_1254888043_1254888343_S0P_0', NULL);
INSERT INTO financial_market_bet VALUES (200859, '2009-10-16 08:27:00', 200379, 'GDAXI', 2, 1.16, 0, '2009-10-16 00:00:00', '2009-10-23 15:30:00', '2009-10-23 23:59:59', true, true, true, 'higher_lower_bet', 'CALL', 'theo=1.03 trade=1.16 recalc=1.15 win=2 [MarkupEngine::Hedge] S=5868.71 r=0.01326 q=0.0003 t=0.0209521182141045 H=5869 L=0 iv=0.397692502162829 ATTRAC=0 (0.451562921501891,0.577114446506774,0.514338684004333,buy,FM=0) delta=0.138523398941272 vega=-0.000260287200372574 theta=0.00124551806854694 gamma=-0.000783836012067541 intradaytime= theo=1.03 spot_time=1255681654 ', 'CALL_GDAXI_2_16_OCT_09_23_OCT_09_5869_0', NULL);
INSERT INTO financial_market_bet VALUES (200899, '2009-10-20 08:46:00', 200379, 'frxEURUSD', 10, 7.26, 0, '2009-10-20 00:00:00', '2009-10-21 00:00:00', '2009-10-21 23:59:59', false, true, true, 'legacy_bet', 'DOUBLEONETOUCH', 'theo=5.97 trade=7.26 recalc=7.24 win=10 [MarkupEngine::Hedge] S=0.9126 r=0.0113 q=0.01326 t=0.00447761288685946 H=0.9163 L=0.9107 iv=0.191 (0.470343699687832,0.724264579356303,0.597304139522068,buy,FM=0) delta=-0.153374253450337 vega=0.0368378823608042 theta=-1.12652750894949 gamma=2.25702621452758 theo=5.97 spot_time=1256028394 ', 'DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107', NULL);
INSERT INTO financial_market_bet VALUES (200919, '2009-10-23 05:42:00', 200379, 'frxUSDCAD', 2, 1.04, 0, '2009-10-23 05:42:01', '2009-10-23 05:42:31', '2009-10-23 05:42:31', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1256276521 ', 'FLASHU_FRXUSDCAD_2_23_OCT_09_S30_05H4201', NULL);
INSERT INTO financial_market_bet VALUES (200959, '2009-10-23 05:43:00', 200379, 'frxUSDCAD', 15, 7.8, 0, '2009-10-23 05:43:16', '2009-10-23 05:43:46', '2009-10-23 05:43:46', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256276598 ', 'FLASHU_FRXUSDCAD_15_23_OCT_09_S30_05H4316', NULL);
INSERT INTO financial_market_bet VALUES (201019, '2009-10-23 05:47:00', 200379, 'frxUSDCAD', 15, 7.8, 0, '2009-10-23 05:47:05', '2009-10-23 05:47:35', '2009-10-23 05:47:35', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256276825 ', 'FLASHU_FRXUSDCAD_15_23_OCT_09_S30_05H4705', NULL);
INSERT INTO financial_market_bet VALUES (201039, '2009-10-23 05:50:00', 200379, 'frxAUDJPY', 15, 7.8, 15, '2009-10-23 05:50:48', '2009-10-23 05:51:18', '2009-10-23 05:51:18', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256277048 ', 'FLASHU_FRXAUDJPY_15_23_OCT_09_S30_05H5048', NULL);
INSERT INTO financial_market_bet VALUES (201079, '2009-10-23 05:56:00', 200379, 'frxAUDJPY', 15, 7.8, 0, '2009-10-23 05:56:48', '2009-10-23 05:57:18', '2009-10-23 05:57:18', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256277409 ', 'FLASHU_FRXAUDJPY_15_23_OCT_09_S30_05H5648', NULL);
INSERT INTO financial_market_bet VALUES (202719, '2009-07-31 17:21:00', 200699, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202739, '2009-07-31 17:21:00', 200679, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202759, '2009-11-03 07:14:00', 200639, 'frxAUDJPY', 2, 1.04, 0, '2009-11-03 07:14:47', '2009-11-03 07:15:17', '2009-11-03 07:15:17', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257232487 ', 'FLASHU_FRXAUDJPY_2_3_NOV_09_S30_07H1447', NULL);
INSERT INTO financial_market_bet VALUES (202779, '2009-11-03 07:15:00', 200639, 'frxAUDJPY', 20, 10.8, 0, '2009-11-03 08:00:00', '2009-11-03 09:00:00', '2009-11-03 09:00:00', false, true, true, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXAUDJPY_20_3_NOV_09_8_9', NULL);
INSERT INTO financial_market_bet VALUES (202399, '2009-07-31 08:21:00', 200579, 'frxXAUUSD', 10000, 3140, 0, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202519, '2009-07-31 08:21:00', 200699, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (200539, '2009-10-16 08:27:00', 200319, 'GDAXI', 2, 1.16, 0, '2009-10-16 00:00:00', '2009-10-23 15:30:00', '2009-10-23 23:59:59', true, true, true, 'higher_lower_bet', 'CALL', 'theo=1.03 trade=1.16 recalc=1.15 win=2 [MarkupEngine::Hedge] S=5868.71 r=0.01326 q=0.0003 t=0.0209521182141045 H=5869 L=0 iv=0.397692502162829 ATTRAC=0 (0.451562921501891,0.577114446506774,0.514338684004333,buy,FM=0) delta=0.138523398941272 vega=-0.000260287200372574 theta=0.00124551806854694 gamma=-0.000783836012067541 intradaytime= theo=1.03 spot_time=1255681654 ', 'CALL_GDAXI_2_16_OCT_09_23_OCT_09_5869_0', NULL);
INSERT INTO financial_market_bet VALUES (200559, '2009-10-20 08:46:00', 200319, 'frxEURUSD', 10, 7.26, 0, '2009-10-20 00:00:00', '2009-10-21 00:00:00', '2009-10-21 23:59:59', false, true, true, 'legacy_bet', 'DOUBLEONETOUCH', 'theo=5.97 trade=7.26 recalc=7.24 win=10 [MarkupEngine::Hedge] S=0.9126 r=0.0113 q=0.01326 t=0.00447761288685946 H=0.9163 L=0.9107 iv=0.191 (0.470343699687832,0.724264579356303,0.597304139522068,buy,FM=0) delta=-0.153374253450337 vega=0.0368378823608042 theta=-1.12652750894949 gamma=2.25702621452758 theo=5.97 spot_time=1256028394 ', 'DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107', NULL);
INSERT INTO financial_market_bet VALUES (200619, '2009-10-23 05:42:00', 200319, 'frxUSDCAD', 2, 1.04, 0, '2009-10-23 05:42:01', '2009-10-23 05:42:31', '2009-10-23 05:42:31', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1256276521 ', 'FLASHU_FRXUSDCAD_2_23_OCT_09_S30_05H4201', NULL);
INSERT INTO financial_market_bet VALUES (200679, '2009-10-23 05:43:00', 200319, 'frxUSDCAD', 15, 7.8, 0, '2009-10-23 05:43:16', '2009-10-23 05:43:46', '2009-10-23 05:43:46', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256276598 ', 'FLASHU_FRXUSDCAD_15_23_OCT_09_S30_05H4316', NULL);
INSERT INTO financial_market_bet VALUES (200699, '2009-10-23 05:47:00', 200319, 'frxUSDCAD', 15, 7.8, 0, '2009-10-23 05:47:05', '2009-10-23 05:47:35', '2009-10-23 05:47:35', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256276825 ', 'FLASHU_FRXUSDCAD_15_23_OCT_09_S30_05H4705', NULL);
INSERT INTO financial_market_bet VALUES (200719, '2009-10-23 05:50:00', 200319, 'frxAUDJPY', 15, 7.8, 15, '2009-10-23 05:50:48', '2009-10-23 05:51:18', '2009-10-23 05:51:18', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256277048 ', 'FLASHU_FRXAUDJPY_15_23_OCT_09_S30_05H5048', NULL);
INSERT INTO financial_market_bet VALUES (200759, '2009-10-23 05:56:00', 200319, 'frxAUDJPY', 15, 7.8, 0, '2009-10-23 05:56:48', '2009-10-23 05:57:18', '2009-10-23 05:57:18', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=7.5 trade=7.8 recalc=7.8 win=15 (0.5,buy) delta=0.015 vega=0 theta=0 gamma=0 theo=7.5 spot_time=1256277409 ', 'FLASHU_FRXAUDJPY_15_23_OCT_09_S30_05H5648', NULL);
INSERT INTO financial_market_bet VALUES (202579, '2009-07-31 11:21:00', 200699, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (200979, '2009-08-14 07:19:00', 200399, 'frxGBPJPY', 30, 15.04, 0, '2009-08-14 07:19:52', '2009-08-14 07:20:22', '2009-08-14 07:20:22', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 intradaytime= theo=1', 'FLASHU_FRXGBPJPY_30_14_AUG_09_S30_07H1952', NULL);
INSERT INTO financial_market_bet VALUES (201159, '2009-04-27 02:24:00', 200459, 'frxXAUUSD', 25000, 142.1, NULL, '2007-02-27 00:00:00', '2007-04-13 21:00:00', '2007-04-13 23:59:59', true, true, false, 'touch_bet', 'ONETOUCH', 'theo=119.3778 trade=142.1 recalc=142.1 win=250 TYPE=ONETOUCH u=FRXXAUUSD S=685.77 r=0.0536 q=0.0003 t=0.12975 H=725 L=0 iv=0.20926 delta=0.0798926950884236 vega=0.0191357567858109 theta=-0.0048166344239883 gamma=0.0062105655409699 intradaytime=0.899930507296734 ATTRAC:0', 'ONETOUCH_FRXXAUUSD_25000_27_FEB_07_13_APR_07_7250000_0', NULL);
INSERT INTO financial_market_bet VALUES (201179, '2009-04-27 02:24:00', 200459, 'frxXAUUSD', 9000, 15001, NULL, '2007-02-27 16:00:01', '2007-05-28 23:59:59', '2007-05-28 23:59:59', true, true, false, 'touch_bet', 'ONETOUCH', 'theo=107.9521 trade=125.1 recalc=125.1 win=250 TYPE=ONETOUCH u=FRXXAUUSD S=685.77 r=0.0539 q=0.0003 t=0.25033 H=750 L=0 iv=0.2177 delta=0.0518198261581446 vega=0.0185469303485308 theta=-0.00260296328054277 gamma=0.00293859599677548 intradaytime=0.899930507296734 ATTRAC:0', 'ONETOUCH_FRXXAUUSD_9000_1172592001_28_MAY_07_7500000_0', NULL);
INSERT INTO financial_market_bet VALUES (201219, '2009-04-27 03:45:00', 200459, 'frxEURUSD', 14500, 15000, NULL, '2009-04-27 06:02:19', '2009-04-27 06:04:19', '2009-04-27 06:04:19', false, true, false, 'higher_lower_bet', 'FLASHD', NULL, 'FLASHD_FRXEURUSD_14500_1240812139_1240812259_S0P_0', NULL);
INSERT INTO financial_market_bet VALUES (201239, '2009-04-27 03:55:00', 200459, 'frxEURUSD', 14500, 1, NULL, '2009-04-27 06:02:19', '2009-04-27 06:04:19', '2009-04-27 06:04:19', false, true, false, 'higher_lower_bet', 'FLASHD', NULL, 'FLASHD_FRXEURUSD_14500_1240812139_1240812259_S0P_0', NULL);
INSERT INTO financial_market_bet VALUES (201279, '2009-04-27 05:58:00', 200459, 'frxEURUSD', 10, 500, NULL, '2009-04-27 06:02:19', '2009-04-27 06:04:19', '2009-04-27 06:04:19', false, true, false, 'higher_lower_bet', 'FLASHU', 'theo=5 trade=5.01 recalc=5.01 win=10 (0.5,buy) delta=0.01 vega=0 theta=0 gamma=0 intradaytime=0.751216122307158 theo=5', 'FLASHU_FRXEURUSD_10_1240812139_1240812259_S0P_0', NULL);
INSERT INTO financial_market_bet VALUES (201319, '2007-02-27 02:24:00', 200499, 'frxXAUUSD', 25000, 142.1, NULL, '2007-02-27 00:00:00', '2007-04-13 21:00:00', '2007-04-13 23:59:59', true, true, false, 'touch_bet', 'ONETOUCH', 'theo=119.3778 trade=142.1 recalc=142.1 win=250 TYPE=ONETOUCH u=FRXXAUUSD S=685.77 r=0.0536 q=0.0003 t=0.12975 H=725 L=0 iv=0.20926 delta=0.0798926950884236 vega=0.0191357567858109 theta=-0.0048166344239883 gamma=0.0062105655409699 intradaytime=0.899930507296734 ATTRAC:0', 'ONETOUCH_FRXXAUUSD_25000_27_FEB_07_13_APR_07_7250000_0', NULL);
INSERT INTO financial_market_bet VALUES (201359, '2007-02-27 02:24:00', 200499, 'frxXAUUSD', 9000, 125.1, NULL, '2007-02-27 00:00:00', '2007-05-28 23:59:59', '2007-05-28 23:59:59', true, true, false, 'touch_bet', 'ONETOUCH', 'theo=107.9521 trade=125.1 recalc=125.1 win=250 TYPE=ONETOUCH u=FRXXAUUSD S=685.77 r=0.0539 q=0.0003 t=0.25033 H=750 L=0 iv=0.2177 delta=0.0518198261581446 vega=0.0185469303485308 theta=-0.00260296328054277 gamma=0.00293859599677548 intradaytime=0.899930507296734 ATTRAC:0', 'ONETOUCH_FRXXAUUSD_9000_27_FEB_07_28_MAY_07_7500000_0', NULL);
INSERT INTO financial_market_bet VALUES (201399, '2007-02-27 03:45:00', 200499, 'frxUSDJPY', 0, 0, NULL, NULL, NULL, NULL, false, true, false, 'legacy_bet', 'SPREADUP', NULL, 'SPREADUP_FRXUSDJPY_0_3000000_1220300', NULL);
INSERT INTO financial_market_bet VALUES (202639, '2009-07-31 13:21:00', 200699, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (203679, '2009-11-11 02:34:00', 200639, 'frxAUDJPY', 2, 1.04, 2, '2009-11-11 02:34:42', '2009-11-11 02:35:12', '2009-11-11 02:35:12', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257906882 ', 'FLASHU_FRXAUDJPY_2_11_NOV_09_S30_02H3442', NULL);
INSERT INTO financial_market_bet VALUES (203719, '2009-11-11 02:39:00', 200639, 'frxAUDJPY', 90, 46.8, 0, '2009-11-11 02:39:21', '2009-11-11 02:39:51', '2009-11-11 02:39:51', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=45 trade=46.8 recalc=46.8 win=90 (0.5,buy) delta=0.09 vega=0 theta=0 gamma=0 theo=45 spot_time=1257907161 ', 'FLASHU_FRXAUDJPY_90_11_NOV_09_S30_02H3921', NULL);
INSERT INTO financial_market_bet VALUES (203999, '2009-05-05 02:27:00', 1202, 'frxEURCHF', 50, 25, NULL, '2009-05-05 06:00:00', '2009-05-05 08:00:00', '2009-05-05 08:00:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXEURCHF_50_5_MAY_09_6_8', NULL);
INSERT INTO financial_market_bet VALUES (204039, '2009-05-05 02:32:00', 1202, 'frxEURCHF', 50, 25, NULL, '2009-05-05 06:00:00', '2009-05-05 09:00:00', '2009-05-05 09:00:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXEURCHF_50_5_MAY_09_6_9', NULL);
INSERT INTO financial_market_bet VALUES (202479, '2009-08-13 12:03:00', 200619, 'FCHI', 500, 396.9, NULL, '2009-08-13 00:00:00', '2006-01-27 16:30:00', '2006-01-27 23:59:59', true, true, false, 'higher_lower_bet', 'PUT', 'theo=348.2965 trade=396.9 recalc=396.9 win=500 TYPE=PUT u=FCHI S=4842.3 r=0.02335 q=0.0234 t=0.041204 H=4900 L=0 iv=0.1156 delta=-0.148613257357714 vega=-0.0148746544665071 theta=0.00602276790084144 gamma=-0.0312186193847232 intradaytime=0.523529411764706 ATTRAC:-4', 'PUT_FCHI_500_13_AUG_09_27_JAN_06_4900_0', NULL);
INSERT INTO financial_market_bet VALUES (201839, '2005-09-21 06:37:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.567,111.568,111.564,111.569,111.572,111.571,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201859, '2005-09-21 06:38:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.583,111.595,111.603,111.595,111.598,111.591,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202499, '2009-07-31 08:21:00', 200679, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (201879, '2005-09-21 06:38:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.598,111.604,111.602,111.607,111.594,111.623,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201899, '2005-09-21 06:39:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.621,111.617,111.608,111.618,111.613,111.627,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202559, '2009-07-31 11:21:00', 200679, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (201919, '2005-09-21 06:39:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.627,111.631,111.635,111.621,111.654,111.658,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201939, '2005-09-21 06:40:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.634,111.644,111.65,111.634,111.63,111.642,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201959, '2005-09-21 06:40:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.625,111.639,111.618,111.614,111.617,111.625,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (203159, '2009-11-09 02:22:00', 200639, 'frxAUDJPY', 60, 32.46, 60, '2009-11-09 03:00:00', '2009-11-09 04:00:00', '2009-11-09 04:00:00', false, true, true, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXAUDJPY_60_9_NOV_09_3_4', NULL);
INSERT INTO financial_market_bet VALUES (205579, '2009-05-08 06:42:00', 1202, 'frxUSDJPY', 50, 30.82, NULL, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, false, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (202619, '2009-07-31 13:21:00', 200679, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (201979, '2005-09-21 06:40:00', 200359, 'frxUSDJPY', 40, 20, 38, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.61,111.62,111.611,111.585,111.587,111.593,', 'RUNBET_DOUBLEDOWN_USD400_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (201999, '2005-09-21 06:40:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.554,111.555,111.543,111.538,111.554,111.54,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202659, '2009-07-31 15:21:00', 200679, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202019, '2005-09-21 06:41:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.538,111.557,111.543,111.53,111.536,111.53,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202039, '2005-09-21 06:41:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.527,111.524,111.528,111.543,111.52,111.528,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202059, '2005-09-21 06:41:00', 200359, 'frxUSDJPY', 40, 20, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.517,111.505,111.515,111.486,111.478,111.482,', 'RUNBET_DOUBLEUP_USD400_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202079, '2005-09-21 06:42:00', 200359, 'frxUSDJPY', 80, 40, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.481,111.47,111.471,111.47,111.464,111.481,', 'RUNBET_DOUBLEDOWN_USD800_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (203699, '2009-11-11 02:39:00', 200639, 'frxAUDJPY', 2, 1.04, 2, '2009-11-11 02:39:06', '2009-11-11 02:39:36', '2009-11-11 02:39:36', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257907146 ', 'FLASHU_FRXAUDJPY_2_11_NOV_09_S30_02H3906', NULL);
INSERT INTO financial_market_bet VALUES (202099, '2005-09-21 06:42:00', 200359, 'frxUSDJPY', 200, 100, 190, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.503,111.498,111.491,111.489,111.488,111.514,', 'RUNBET_DOUBLEUP_USD2000_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202119, '2005-09-21 06:42:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.491,111.503,111.515,111.499,111.495,111.503,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202139, '2005-09-21 06:43:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.502,111.507,111.502,111.493,111.499,111.498,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202159, '2005-09-21 06:43:00', 200359, 'frxUSDJPY', 40, 20, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.472,111.475,111.472,111.486,111.47,111.48,', 'RUNBET_DOUBLEDOWN_USD400_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (203739, '2009-11-11 07:50:00', 200639, 'frxAUDJPY', 2, 1.04, 0, '2009-11-11 07:50:22', '2009-11-11 07:50:52', '2009-11-11 07:50:52', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257925822 ', 'FLASHU_FRXAUDJPY_2_11_NOV_09_S30_07H5022', NULL);
INSERT INTO financial_market_bet VALUES (202179, '2005-09-21 06:43:00', 200359, 'frxUSDJPY', 80, 40, 76, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.48,111.479,111.49,111.485,111.493,111.499,', 'RUNBET_DOUBLEUP_USD800_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202199, '2005-09-21 06:44:00', 200359, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.49,111.499,111.496,111.497,111.493,111.492,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202219, '2005-09-21 06:44:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.524,111.525,111.504,111.51,111.507,111.508,', 'RUNBET_DOUBLEUP_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202239, '2005-09-21 06:44:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.481,111.509,111.517,111.494,111.501,111.51,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202259, '2005-09-21 06:45:00', 200359, 'frxUSDJPY', 60, 30, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.486,111.48,111.504,111.51,111.504,111.486,', 'RUNBET_DOUBLEUP_USD600_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202279, '2005-09-21 06:45:00', 200359, 'frxUSDJPY', 100, 50, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.488,111.494,111.498,111.496,111.517,111.505,', 'RUNBET_DOUBLEDOWN_USD1000_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202299, '2005-09-21 06:45:00', 200359, 'frxUSDJPY', 250, 125, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEUP', 'frxUSDJPY forecast=UP Run=111.512,111.501,111.512,111.509,111.515,111.509,', 'RUNBET_DOUBLEUP_USD2500_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202319, '2005-09-21 06:46:00', 200359, 'frxUSDJPY', 250, 125, 237.5, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.518,111.514,111.529,111.523,111.525,111.513,', 'RUNBET_DOUBLEDOWN_USD2500_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (202339, '2005-09-21 06:46:00', 200359, 'frxUSDJPY', 20, 10, NULL, NULL, NULL, NULL, false, true, false, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=111.487,111.499,111.484,111.497,111.484,111.481,', 'RUNBET_DOUBLEDOWN_USD200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (204079, '2009-05-07 02:46:00', 1202, 'frxEURCHF', 50, 25, NULL, '2009-05-07 06:00:00', '2009-05-07 09:00:00', '2009-05-07 09:00:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXEURCHF_50_7_MAY_09_6_9', NULL);
INSERT INTO financial_market_bet VALUES (202839, '2009-11-03 07:17:00', 200639, 'frxAUDJPY', 70, 38.47, 0, '2009-11-03 07:17:53', '2009-11-03 07:22:53', '2009-11-03 07:22:53', false, true, true, 'higher_lower_bet', 'CALL', 'theo=34.97 trade=38.47 recalc=38.47 win=70 [MarkupEngine::Hedge] S=80.98 r=0.00568 q=0.05213 t=9.51293759512938e-06 H=80.98 L=0 iv=0.236999968651127 (0.449613012380696,0.549613012380696,0.499613012380696,buy,FM=0) delta=382.034219859719 vega=6.67451703122776e-05 theta=3.90119173209922 gamma=26.9962564778226 theo=34.97 spot_time=1257232673 ', 'CALL_FRXAUDJPY_70_1257232673_1257232973_S0P_0', NULL);
INSERT INTO financial_market_bet VALUES (202939, '2009-11-04 10:41:00', 200639, 'frxAUDJPY', 2, 1.04, 0, '2009-11-04 10:41:22', '2009-11-04 10:41:52', '2009-11-04 10:41:52', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257331282 ', 'FLASHU_FRXAUDJPY_2_4_NOV_09_S30_10H4122', NULL);
INSERT INTO financial_market_bet VALUES (202999, '2009-11-05 02:25:00', 200639, 'frxAUDJPY', 80, 43.26, NULL, '2009-11-05 14:00:00', '2009-11-05 18:00:00', '2009-11-05 18:00:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXAUDJPY_80_5_NOV_09_14_18', NULL);
INSERT INTO financial_market_bet VALUES (203019, '2009-11-05 03:33:00', 200639, 'frxAUDJPY', 2, 1.08, 0, '2009-11-05 04:00:00', '2009-11-05 05:00:00', '2009-11-05 05:00:00', false, true, true, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXAUDJPY_2_5_NOV_09_4_5', NULL);
INSERT INTO financial_market_bet VALUES (203059, '2009-11-05 05:46:00', 200639, 'frxAUDJPY', 50, 23.66, 0, '2009-11-05 05:46:12', '2009-11-05 05:51:12', '2009-11-05 05:51:12', false, true, true, 'higher_lower_bet', 'CALL', 'theo=21.18 trade=23.66 recalc=23.68 win=50 [MarkupEngine::Hedge] S=82.05 r=0.00568 q=0.05213 t=9.51293759512938e-06 H=82.06 L=0 iv=0.205999978497277 (0.373548878168691,0.473548878168691,0.423548878168691,buy,FM=0) delta=308.163981194486 vega=0.0376297522575727 theta=-537.946399685496 gamma=955.290700801182 theo=21.18 spot_time=1257399972 ', 'CALL_FRXAUDJPY_50_1257399972_1257400272_S1P_0', NULL);
INSERT INTO financial_market_bet VALUES (203099, '2009-11-05 06:33:00', 200639, 'frxAUDJPY', 20, 9.77, 20, '2009-11-05 00:00:00', '2009-11-12 23:59:59', '2009-11-12 23:59:59', true, true, true, 'touch_bet', 'ONETOUCH', 'theo=8.57 trade=9.77 recalc=9.77 win=20 [MarkupEngine::Hedge] S=82.07 r=0.00568 q=0.05213 t=0.021169964485033 H=83.32 L=0 iv=0.138116787798239 (0.368671613549441,0.488671613549441,0.428671613549441,buy,FM=0) delta=5.97661826085479 vega=0.09295611798753 theta=-0.558884310351264 gamma=2.45204323440237 theo=8.57 spot_time=1257402784 ', 'ONETOUCH_FRXAUDJPY_20_5_NOV_09_12_NOV_09_833200_0', NULL);
INSERT INTO financial_market_bet VALUES (203119, '2009-11-05 06:34:00', 200639, 'frxAUDJPY', 20, 9.77, 20, '2009-11-05 00:00:00', '2009-11-12 23:59:59', '2009-11-12 23:59:59', true, true, true, 'touch_bet', 'ONETOUCH', 'theo=8.57 trade=9.77 recalc=9.77 win=20 [MarkupEngine::Hedge] S=82.07 r=0.00568 q=0.05213 t=0.021169964485033 H=83.32 L=0 iv=0.138116787798239 (0.368671613549441,0.488671613549441,0.428671613549441,buy,FM=0) delta=5.97661826085479 vega=0.09295611798753 theta=-0.558884310351264 gamma=2.45204323440237 theo=8.57 spot_time=1257402844 ', 'ONETOUCH_FRXAUDJPY_20_5_NOV_09_12_NOV_09_833200_0', NULL);
INSERT INTO financial_market_bet VALUES (203199, '2009-11-09 06:50:00', 200639, 'frxAUDJPY', 20, 10.4, 20, '2009-11-09 06:50:38', '2009-11-09 06:51:08', '2009-11-09 06:51:08', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257749438 ', 'FLASHU_FRXAUDJPY_20_9_NOV_09_S30_06H5038', NULL);
INSERT INTO financial_market_bet VALUES (203259, '2009-11-09 06:52:00', 200639, 'frxAUDJPY', 20, 10.4, 0, '2009-11-09 06:52:55', '2009-11-09 06:53:25', '2009-11-09 06:53:25', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257749575 ', 'FLASHU_FRXAUDJPY_20_9_NOV_09_S30_06H5255', NULL);
INSERT INTO financial_market_bet VALUES (203319, '2009-11-09 09:59:00', 200639, 'frxAUDJPY', 90, 46.8, 90, '2009-11-09 09:59:51', '2009-11-09 10:00:21', '2009-11-09 10:00:21', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=45 trade=46.8 recalc=46.8 win=90 (0.5,buy) delta=0.09 vega=0 theta=0 gamma=0 theo=45 spot_time=1257760791 ', 'FLASHU_FRXAUDJPY_90_9_NOV_09_S30_09H5951', NULL);
INSERT INTO financial_market_bet VALUES (203359, '2009-11-09 10:00:00', 200639, 'frxAUDJPY', 90, 46.8, 0, '2009-11-09 10:00:11', '2009-11-09 10:00:41', '2009-11-09 10:00:41', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=45 trade=46.8 recalc=46.8 win=90 (0.5,buy) delta=0.09 vega=0 theta=0 gamma=0 theo=45 spot_time=1257760811 ', 'FLASHU_FRXAUDJPY_90_9_NOV_09_S30_10H0011', NULL);
INSERT INTO financial_market_bet VALUES (203379, '2009-11-09 10:00:00', 200639, 'frxAUDJPY', 90, 46.8, 0, '2009-11-09 10:00:38', '2009-11-09 10:01:08', '2009-11-09 10:01:08', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=45 trade=46.8 recalc=46.8 win=90 (0.5,buy) delta=0.09 vega=0 theta=0 gamma=0 theo=45 spot_time=1257760838 ', 'FLASHU_FRXAUDJPY_90_9_NOV_09_S30_10H0038', NULL);
INSERT INTO financial_market_bet VALUES (203399, '2009-11-09 10:01:00', 200639, 'frxAUDJPY', 90, 48.62, NULL, '2009-11-09 11:00:00', '2009-11-09 12:00:00', '2009-11-09 12:00:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXAUDJPY_90_9_NOV_09_11_12', NULL);
INSERT INTO financial_market_bet VALUES (203419, '2009-11-10 08:55:00', 200639, 'frxAUDJPY', 20, 10.4, 0, '2009-11-10 08:55:39', '2009-11-10 08:56:09', '2009-11-10 08:56:09', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257843339 ', 'FLASHU_FRXAUDJPY_20_10_NOV_09_S30_08H5539', NULL);
INSERT INTO financial_market_bet VALUES (203439, '2009-11-10 08:56:00', 200639, 'frxAUDJPY', 20, 10.4, 0, '2009-11-10 08:56:51', '2009-11-10 08:57:21', '2009-11-10 08:57:21', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257843411 ', 'FLASHU_FRXAUDJPY_20_10_NOV_09_S30_08H5651', NULL);
INSERT INTO financial_market_bet VALUES (203459, '2009-11-10 09:20:00', 200639, 'frxAUDJPY', 20, 10.4, 0, '2009-11-10 09:20:54', '2009-11-10 09:21:24', '2009-11-10 09:21:24', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257844854 ', 'FLASHU_FRXAUDJPY_20_10_NOV_09_S30_09H2054', NULL);
INSERT INTO financial_market_bet VALUES (203479, '2009-11-10 09:39:00', 200639, 'frxAUDJPY', 20, 10.4, 20, '2009-11-10 09:39:51', '2009-11-10 09:40:21', '2009-11-10 09:40:21', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257845992 ', 'FLASHU_FRXAUDJPY_20_10_NOV_09_S30_09H3951', NULL);
INSERT INTO financial_market_bet VALUES (203499, '2009-11-10 09:48:00', 200639, 'frxAUDJPY', 20, 10.4, 0, '2009-11-10 09:48:44', '2009-11-10 09:49:14', '2009-11-10 09:49:14', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257846525 ', 'FLASHU_FRXAUDJPY_20_10_NOV_09_S30_09H4844', NULL);
INSERT INTO financial_market_bet VALUES (203519, '2009-11-10 09:50:00', 200639, 'frxAUDJPY', 20, 10.4, 0, '2009-11-10 09:50:27', '2009-11-10 09:50:57', '2009-11-10 09:50:57', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257846627 ', 'FLASHU_FRXAUDJPY_20_10_NOV_09_S30_09H5027', NULL);
INSERT INTO financial_market_bet VALUES (203539, '2009-11-10 09:55:00', 200639, 'frxAUDJPY', 20, 10.4, 20, '2009-11-10 09:55:40', '2009-11-10 09:56:10', '2009-11-10 09:56:10', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257846940 ', 'FLASHU_FRXAUDJPY_20_10_NOV_09_S30_09H5540', NULL);
INSERT INTO financial_market_bet VALUES (203599, '2009-11-10 09:59:00', 200639, 'frxAUDJPY', 20, 10.4, 0, '2009-11-10 09:59:47', '2009-11-10 10:00:17', '2009-11-10 10:00:17', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257847187 ', 'FLASHU_FRXAUDJPY_20_10_NOV_09_S30_09H5947', NULL);
INSERT INTO financial_market_bet VALUES (203659, '2009-11-11 02:00:00', 200639, 'frxAUDJPY', 2, 1.04, 2, '2009-11-11 02:00:15', '2009-11-11 02:00:45', '2009-11-11 02:00:45', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257904815 ', 'FLASHU_FRXAUDJPY_2_11_NOV_09_S30_02H0015', NULL);
INSERT INTO financial_market_bet VALUES (203639, '2009-11-11 01:56:00', 200639, 'frxAUDJPY', 2, 1.04, 2, '2009-11-11 01:56:43', '2009-11-11 01:57:13', '2009-11-11 01:57:13', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257904603 ', 'FLASHU_FRXAUDJPY_2_11_NOV_09_S30_01H5643', NULL);
INSERT INTO financial_market_bet VALUES (203619, '2009-11-10 09:59:00', 200639, 'frxAUDJPY', 20, 10.4, 0, '2009-11-10 09:59:57', '2009-11-10 10:00:27', '2009-11-10 10:00:27', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257847197 ', 'FLASHU_FRXAUDJPY_20_10_NOV_09_S30_09H5957', NULL);
INSERT INTO financial_market_bet VALUES (203579, '2009-11-10 09:59:00', 200639, 'frxAUDJPY', 20, 10.4, 0, '2009-11-10 09:59:35', '2009-11-10 10:00:05', '2009-11-10 10:00:05', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257847176 ', 'FLASHU_FRXAUDJPY_20_10_NOV_09_S30_09H5935', NULL);
INSERT INTO financial_market_bet VALUES (203559, '2009-11-10 09:59:00', 200639, 'frxAUDJPY', 20, 10.4, 20, '2009-11-10 09:59:02', '2009-11-10 09:59:32', '2009-11-10 09:59:32', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=10 trade=10.4 recalc=10.4 win=20 (0.5,buy) delta=0.02 vega=0 theta=0 gamma=0 theo=10 spot_time=1257847143 ', 'FLASHU_FRXAUDJPY_20_10_NOV_09_S30_09H5902', NULL);
INSERT INTO financial_market_bet VALUES (203899, '2009-05-05 02:16:00', 1202, 'frxEURCHF', 50, 25, NULL, '2009-05-05 06:00:00', '2009-05-05 07:00:00', '2009-05-05 07:00:00', false, true, false, 'higher_lower_bet', 'INTRADU', NULL, 'INTRADU_FRXEURCHF_50_5_MAY_09_6_7', NULL);
INSERT INTO financial_market_bet VALUES (202799, '2009-07-31 19:21:00', 200699, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202859, '2009-07-31 21:21:00', 200699, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202899, '2009-07-31 23:21:00', 200699, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202959, '2009-07-31 23:49:00', 200699, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=114.136,114.139,114.101,114.104,114.138,114.125,', 'RUNBET_DOUBLEDOWN_GBP200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (203179, '2009-08-13 12:00:00', 200799, 'FTSE', 500, 376, NULL, '2009-08-13 00:00:00', '2006-01-27 16:30:00', '2006-01-27 23:59:59', true, true, false, 'higher_lower_bet', 'PUT', 'theo=326.5257 trade=376 recalc=378.8 win=500 TYPE=PUT u=FTSE S=5701.7 r=0.0464 q=0.0347 t=0.04122 H=5750 L=0 iv=0.1013 delta=-0.178923910279832 vega=-0.0136731597908051 theta=0.00495105459849295 gamma=-0.0327372153570317 intradaytime=0.529411764705882 ATTRAC:-4', 'PUT_FTSE_500_13_AUG_09_27_JAN_06_5750_0', NULL);
INSERT INTO financial_market_bet VALUES (203219, '2009-08-13 12:03:00', 200799, 'FCHI', 500, 396.9, NULL, '2009-08-13 00:00:00', '2006-01-27 16:30:00', '2006-01-27 23:59:59', true, true, false, 'higher_lower_bet', 'PUT', 'theo=348.2965 trade=396.9 recalc=396.9 win=500 TYPE=PUT u=FCHI S=4842.3 r=0.02335 q=0.0234 t=0.041204 H=4900 L=0 iv=0.1156 delta=-0.148613257357714 vega=-0.0148746544665071 theta=0.00602276790084144 gamma=-0.0312186193847232 intradaytime=0.523529411764706 ATTRAC:-4', 'PUT_FCHI_500_13_AUG_09_27_JAN_06_4900_0', NULL);
INSERT INTO financial_market_bet VALUES (203239, '2009-11-09 09:59:00', 200799, 'frxAUDJPY', 90, 46.8, 90, '2009-11-09 09:59:51', '2009-11-09 10:00:21', '2009-11-09 10:00:21', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=45 trade=46.8 recalc=46.8 win=90 (0.5,buy) delta=0.09 vega=0 theta=0 gamma=0 theo=45 spot_time=1257760791 ', 'FLASHU_FRXAUDJPY_90_9_NOV_09_S30_09H5951', NULL);
INSERT INTO financial_market_bet VALUES (202819, '2009-07-31 19:21:00', 200679, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202879, '2009-07-31 21:21:00', 200679, 'frxXAUUSD', 10000, 3140, 0, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202919, '2009-07-31 23:21:00', 200679, 'frxXAUUSD', 10000, 3140, 10000, '2009-07-31 08:21:24', '2009-07-31 08:26:24', '2009-07-31 08:26:24', false, true, true, 'higher_lower_bet', 'CALL', 'theo=2.49 trade=3.14 recalc=3.09 win=10 [MarkupEngine::Hedge] S=936.37 r=0.02421 q=0.0003 t=9.38609842719432e-06 H=936.74 L=0 iv=0.19 ATTRAC=0 (0.18869654978049,0.30869654978049,0.24869654978049,buy,FM=) delta=54.4400968585919 vega=0.0214859305445654 theta=-313.934900750414 gamma=634.422510481039 intradaytime= theo=2.49', 'CALL_FRXXAUUSD_10000_1249028484_1249028784_9367400_0', NULL);
INSERT INTO financial_market_bet VALUES (202979, '2009-07-31 23:49:00', 200679, 'frxUSDJPY', 20, 10, 19, NULL, NULL, NULL, false, true, true, 'run_bet', 'RUNBET_DOUBLEDOWN', 'frxUSDJPY forecast=DOWN Run=114.136,114.139,114.101,114.104,114.138,114.125,', 'RUNBET_DOUBLEDOWN_GBP200_frxUSDJPY_5', NULL);
INSERT INTO financial_market_bet VALUES (203759, '2009-11-12 04:08:00', 200639, 'frxAUDJPY', 2, 1.04, 0, '2009-11-12 04:08:49', '2009-11-12 04:09:19', '2009-11-12 04:09:19', false, true, true, 'higher_lower_bet', 'FLASHU', 'theo=1 trade=1.04 recalc=1.04 win=2 (0.5,buy) delta=0.002 vega=0 theta=0 gamma=0 theo=1 spot_time=1257998929 ', 'FLASHU_FRXAUDJPY_2_12_NOV_09_S30_04H0849', NULL);
INSERT INTO financial_market_bet VALUES (205279, '2009-05-08 06:26:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (203959, '2009-05-05 02:18:00', 1202, 'frxXAUUSD', 50, 18.1, 8.32, '2009-05-05 00:00:00', '2009-05-12 23:59:59', '2009-05-12 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', 'theo=12.5 trade=18.1 recalc=18.1 win=50 [MarkupEngine::Hedge] S=904.65 r=0.0104 q=0.027833 t=0.0216538876204972 H=912.19 L=897.12 iv=0.211166536239101 ATTRAC=-2 (0.140053510461251,0.360053510461251,0.250053510461251,buy,FM=) delta=0.0887467305655004 vega=-0.103117721157029 theta=0.653065622264854 gamma=-1.06794076594247 intradaytime= theo=12.5 ', 'EXPIRYRANGE_FRXXAUUSD_50_5_MAY_09_12_MAY_09_9121900_8971200', NULL);
INSERT INTO financial_market_bet VALUES (204099, '2009-05-07 09:55:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204139, '2009-05-07 09:55:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204159, '2009-05-07 09:56:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204199, '2009-05-07 09:58:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204219, '2009-05-08 02:16:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204259, '2009-05-08 02:20:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204299, '2009-05-08 02:22:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204319, '2009-05-08 02:22:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204359, '2009-05-08 02:49:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204399, '2009-05-08 02:50:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204439, '2009-05-08 02:52:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204479, '2009-05-08 02:59:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204519, '2009-05-08 03:03:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204559, '2009-05-08 03:06:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204619, '2009-05-08 03:07:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204659, '2009-05-08 03:08:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204699, '2009-05-08 03:08:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204739, '2009-05-08 03:42:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204799, '2009-05-08 03:47:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204839, '2009-05-08 03:47:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204879, '2009-05-08 03:55:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204919, '2009-05-08 04:15:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204959, '2009-05-08 04:18:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (204999, '2009-05-08 04:19:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205039, '2009-05-08 04:20:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205079, '2009-05-08 04:23:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205119, '2009-05-08 04:23:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205419, '2009-05-08 06:29:00', 1202, 'frxUSDJPY', 50, 30.82, NULL, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, false, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205159, '2009-05-08 06:17:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205459, '2009-05-08 06:30:00', 1202, 'frxUSDJPY', 50, 30.82, NULL, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, false, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205199, '2009-05-08 06:20:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205499, '2009-05-08 06:31:00', 1202, 'frxUSDJPY', 50, 30.82, NULL, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, false, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205239, '2009-05-08 06:20:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205539, '2009-05-08 06:36:00', 1202, 'frxUSDJPY', 50, 30.82, NULL, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, false, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205319, '2009-05-08 06:27:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205619, '2009-05-08 06:43:00', 1202, 'frxUSDJPY', 50, 30.82, NULL, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, false, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);
INSERT INTO financial_market_bet VALUES (205359, '2009-05-08 06:28:00', 1202, 'frxUSDJPY', 50, 30.82, 8.32, '2009-05-05 00:00:00', '2009-05-06 23:59:59', '2009-05-06 23:59:59', true, true, true, 'range_bet', 'EXPIRYRANGE', NULL, 'EXPIRYRANGE_FRXUSDJPY_50_5_MAY_09_6_MAY_09_995000_981400', NULL);


--
-- Data for Name: higher_lower_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

INSERT INTO higher_lower_bet VALUES (200039, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200059, NULL, 82.87, NULL);
INSERT INTO higher_lower_bet VALUES (200139, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200379, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200539, NULL, 5869, NULL);
INSERT INTO higher_lower_bet VALUES (200519, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200579, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200619, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200659, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200679, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200699, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200719, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200759, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200859, NULL, 5869, NULL);
INSERT INTO higher_lower_bet VALUES (200919, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200959, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (200979, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201019, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201039, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201079, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201219, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201239, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201279, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201679, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201699, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201719, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201739, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201759, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201779, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201799, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (201819, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (202359, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202379, NULL, 5750, NULL);
INSERT INTO higher_lower_bet VALUES (202399, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202419, NULL, 4900, NULL);
INSERT INTO higher_lower_bet VALUES (202439, NULL, 5750, NULL);
INSERT INTO higher_lower_bet VALUES (202479, NULL, 4900, NULL);
INSERT INTO higher_lower_bet VALUES (202499, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202519, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202559, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202579, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202599, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (202619, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202639, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202659, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202679, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202699, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (202719, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202739, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202759, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (202779, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (202799, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202819, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202839, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (202859, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202879, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202899, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202919, NULL, 936.74, NULL);
INSERT INTO higher_lower_bet VALUES (202939, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (202999, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203019, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203059, 'S1P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203159, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203179, NULL, 5750, NULL);
INSERT INTO higher_lower_bet VALUES (203199, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203219, NULL, 4900, NULL);
INSERT INTO higher_lower_bet VALUES (203239, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203259, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203319, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203359, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203379, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203399, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203419, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203439, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203459, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203479, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203499, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203519, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203539, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203559, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203579, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203599, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203619, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203639, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203659, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203679, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203699, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203719, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203739, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203759, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203899, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (203999, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (204039, 'S0P', NULL, NULL);
INSERT INTO higher_lower_bet VALUES (204079, 'S0P', NULL, NULL);


--
-- Data for Name: legacy_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

INSERT INTO legacy_bet VALUES (200439, 0.9107, 0.9163, NULL, NULL, NULL, NULL, NULL, NULL, 'DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107');
INSERT INTO legacy_bet VALUES (200459, 0.9107, 0.9163, NULL, NULL, NULL, NULL, NULL, NULL, 'DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107');
INSERT INTO legacy_bet VALUES (200559, 0.9107, 0.9163, NULL, NULL, NULL, NULL, NULL, NULL, 'DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107');
INSERT INTO legacy_bet VALUES (200899, 0.9107, 0.9163, NULL, NULL, NULL, NULL, NULL, NULL, 'DOUBLEONETOUCH_FRXEURUSD_10_20_OCT_09_21_OCT_09_9163_9107');
INSERT INTO legacy_bet VALUES (201399, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'SPREADUP_FRXUSDJPY_0_3000000_1220300');


--
-- Data for Name: range_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

INSERT INTO range_bet VALUES (203959, NULL, 897.12, NULL, 912.19, NULL);
INSERT INTO range_bet VALUES (204099, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204139, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204159, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204199, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204219, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204259, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204299, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204319, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204359, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204399, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204439, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204479, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204519, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204559, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204619, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204659, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204699, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204739, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204799, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204839, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204879, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204919, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204959, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (204999, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205039, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205079, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205119, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205159, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205199, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205239, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205279, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205319, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205359, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205419, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205459, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205499, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205539, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205579, NULL, 98.14, NULL, 99.5, NULL);
INSERT INTO range_bet VALUES (205619, NULL, 98.14, NULL, 99.5, NULL);


--
-- Data for Name: run_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

INSERT INTO run_bet VALUES (200499, 5, NULL, 'up');
INSERT INTO run_bet VALUES (200599, 5, NULL, 'up');
INSERT INTO run_bet VALUES (200639, 5, NULL, 'down');
INSERT INTO run_bet VALUES (200739, 5, NULL, 'down');
INSERT INTO run_bet VALUES (200779, 5, NULL, 'up');
INSERT INTO run_bet VALUES (200799, 5, NULL, 'down');
INSERT INTO run_bet VALUES (200819, 5, NULL, 'down');
INSERT INTO run_bet VALUES (200839, 5, NULL, 'down');
INSERT INTO run_bet VALUES (200879, 5, NULL, 'up');
INSERT INTO run_bet VALUES (200939, 5, NULL, 'up');
INSERT INTO run_bet VALUES (200999, 5, NULL, 'down');
INSERT INTO run_bet VALUES (201059, 5, NULL, 'down');
INSERT INTO run_bet VALUES (201099, 5, NULL, 'down');
INSERT INTO run_bet VALUES (201119, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201139, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201199, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201259, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201299, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201339, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201379, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201419, 5, NULL, 'down');
INSERT INTO run_bet VALUES (201439, 5, NULL, 'down');
INSERT INTO run_bet VALUES (201459, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201479, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201499, 5, NULL, 'down');
INSERT INTO run_bet VALUES (201519, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201539, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201559, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201579, 5, NULL, 'down');
INSERT INTO run_bet VALUES (201599, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201619, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201639, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201659, 5, NULL, 'down');
INSERT INTO run_bet VALUES (201839, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201859, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201879, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201899, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201919, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201939, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201959, 5, NULL, 'up');
INSERT INTO run_bet VALUES (201979, 5, NULL, 'down');
INSERT INTO run_bet VALUES (201999, 5, NULL, 'down');
INSERT INTO run_bet VALUES (202019, 5, NULL, 'down');
INSERT INTO run_bet VALUES (202039, 5, NULL, 'down');
INSERT INTO run_bet VALUES (202059, 5, NULL, 'up');
INSERT INTO run_bet VALUES (202079, 5, NULL, 'down');
INSERT INTO run_bet VALUES (202099, 5, NULL, 'up');
INSERT INTO run_bet VALUES (202119, 5, NULL, 'up');
INSERT INTO run_bet VALUES (202139, 5, NULL, 'up');
INSERT INTO run_bet VALUES (202159, 5, NULL, 'down');
INSERT INTO run_bet VALUES (202179, 5, NULL, 'up');
INSERT INTO run_bet VALUES (202199, 5, NULL, 'up');
INSERT INTO run_bet VALUES (202219, 5, NULL, 'up');
INSERT INTO run_bet VALUES (202239, 5, NULL, 'down');
INSERT INTO run_bet VALUES (202259, 5, NULL, 'up');
INSERT INTO run_bet VALUES (202279, 5, NULL, 'down');
INSERT INTO run_bet VALUES (202299, 5, NULL, 'up');
INSERT INTO run_bet VALUES (202319, 5, NULL, 'down');
INSERT INTO run_bet VALUES (202339, 5, NULL, 'down');
INSERT INTO run_bet VALUES (202959, 5, NULL, 'down');
INSERT INTO run_bet VALUES (202979, 5, NULL, 'down');


--
-- Data for Name: touch_bet; Type: TABLE DATA; Schema: bet; Owner: postgres
--

INSERT INTO touch_bet VALUES (201159, NULL, 725, NULL);
INSERT INTO touch_bet VALUES (201179, NULL, 750, NULL);
INSERT INTO touch_bet VALUES (201319, NULL, 725, NULL);
INSERT INTO touch_bet VALUES (201359, NULL, 750, NULL);
INSERT INTO touch_bet VALUES (203099, NULL, 83.32, NULL);
INSERT INTO touch_bet VALUES (203119, NULL, 83.32, NULL);

SET search_path = betonmarkets, pg_catalog;


--
-- Data for Name: client_authentication_document; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

INSERT INTO client_authentication_document VALUES (1838, 'passport', 'txt', '/home/git/regentmarkets/bom/t/data/db/clientIDscans/CR/CR0009.passport.1233801953.txt', 'CR0009', 'ID_DOCUMENT', NULL);
INSERT INTO client_authentication_document VALUES (1878, 'address', 'txt', '/home/git/regentmarkets/bom/t/data/db/clientIDscans/CR/CR0009.address.1233817301.txt', 'CR0009', 'ID_DOCUMENT', NULL);
INSERT INTO client_authentication_document VALUES (1858, 'certified_passport', 'png', '/home/git/regentmarkets/bom/t/data/db/clientIDscans/CR/CR0009.certified_passport.png', 'CR0009', 'ID_DOCUMENT', NULL);


--
-- Data for Name: client_authentication_method; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

INSERT INTO client_authentication_method VALUES (218, 'MLT0012', 'PHONE_NUMBER', '2009-02-25 09:41:00', 'pass', '60122373211');
INSERT INTO client_authentication_method VALUES (238, 'MLT0012', 'ADDRESS', '2009-02-23 00:00:00', 'pending', 'address   tiwn 12341 Indonesia');
INSERT INTO client_authentication_method VALUES (278, 'MLT0013', 'PHONE_NUMBER', '2009-08-13 09:35:00', 'pass', '611234567');
INSERT INTO client_authentication_method VALUES (298, 'MLT0013', 'ADDRESS', '2009-08-13 00:00:00', 'pending', 'test test   test 12345 Australia');
INSERT INTO client_authentication_method VALUES (338, 'MLT0014', 'PHONE_NUMBER', '2009-08-13 10:03:00', 'pass', '611234549');
INSERT INTO client_authentication_method VALUES (358, 'MLT0014', 'ADDRESS', '2009-08-13 00:00:00', 'pending', 'test test   test 11111 Australia');
INSERT INTO client_authentication_method VALUES (398, 'MLT0015', 'PHONE_NUMBER', '2009-08-31 10:03:00', 'pass', '611234549');
INSERT INTO client_authentication_method VALUES (418, 'MLT0015', 'ADDRESS', '2009-08-31 00:00:00', 'pending', 'test test   test 11111 Australia');
INSERT INTO client_authentication_method VALUES (458, 'MLT0016', 'PHONE_NUMBER', '2009-07-31 10:03:00', 'pass', '611234549');
INSERT INTO client_authentication_method VALUES (478, 'MLT0016', 'ADDRESS', '2009-07-31 00:00:00', 'pending', 'test test   test 11111 Australia');
INSERT INTO client_authentication_method VALUES (498, 'MX0012', 'PHONE_NUMBER', '2009-02-25 09:41:00', 'pass', '60122373211');
INSERT INTO client_authentication_method VALUES (518, 'MX0012', 'ADDRESS', '2009-02-23 00:00:00', 'pending', 'address   tiwn 12341 Indonesia');
INSERT INTO client_authentication_method VALUES (558, 'MX0013', 'PHONE_NUMBER', '2009-08-13 09:35:00', 'pass', '611234567');
INSERT INTO client_authentication_method VALUES (578, 'MX0013', 'ADDRESS', '2009-08-13 00:00:00', 'pending', 'test test   test 12345 Australia');
INSERT INTO client_authentication_method VALUES (618, 'MX0014', 'PHONE_NUMBER', '2009-08-13 10:03:00', 'pass', '611234549');
INSERT INTO client_authentication_method VALUES (638, 'MX0014', 'ADDRESS', '2009-08-13 00:00:00', 'pending', 'test test   test 11111 Australia');
INSERT INTO client_authentication_method VALUES (678, 'MX0015', 'PHONE_NUMBER', '2009-08-31 10:03:00', 'pass', '611234549');
INSERT INTO client_authentication_method VALUES (698, 'MX0015', 'ADDRESS', '2009-08-31 00:00:00', 'pending', 'test test   test 11111 Australia');
INSERT INTO client_authentication_method VALUES (738, 'MX0016', 'PHONE_NUMBER', '2009-07-31 10:03:00', 'pass', '611234549');
INSERT INTO client_authentication_method VALUES (758, 'MX0016', 'ADDRESS', '2009-07-31 00:00:00', 'pending', 'test test   test 11111 Australia');
INSERT INTO client_authentication_method VALUES (778, 'CR0002', 'ADDRESS', '2010-01-10 00:00:00', 'pass', 'test1 test2 te12st');
INSERT INTO client_authentication_method VALUES (798, 'CR0003', 'ADDRESS', '2010-01-10 00:00:00', 'pass', 'test1 test2 te12st');
INSERT INTO client_authentication_method VALUES (818, 'CR0004', 'ADDRESS', '2010-01-10 00:00:00', 'pass', 'test1 test2 te12st');
INSERT INTO client_authentication_method VALUES (838, 'CR0005', 'ADDRESS', '2010-01-10 00:00:00', 'pass', 'test1 test2 te12st');
INSERT INTO client_authentication_method VALUES (858, 'CR0006', 'ADDRESS', '2010-01-10 00:00:00', 'pass', 'test1 test2 te12st');
INSERT INTO client_authentication_method VALUES (878, 'CR0007', 'PHONE_NUMBER', '2008-03-20 02:11:00', 'pass', '8187876876');
INSERT INTO client_authentication_method VALUES (898, 'CR0007', 'ADDRESS', '2010-01-10 00:00:00', 'pass', 'test1 test2 te12st');
INSERT INTO client_authentication_method VALUES (918, 'CR0007', 'ID_DOCUMENT', NULL, 'pass', '');
INSERT INTO client_authentication_method VALUES (938, 'CR0008', 'PHONE_NUMBER', '2008-03-20 02:11:00', 'pass', '8187876876');
INSERT INTO client_authentication_method VALUES (958, 'CR0008', 'ADDRESS', '2010-01-10 00:00:00', 'pass', 'test1 test2 te12st');
INSERT INTO client_authentication_method VALUES (978, 'CR0009', 'PHONE_NUMBER', '2009-03-20 02:10:00', 'pass', '00869145685792');
INSERT INTO client_authentication_method VALUES (998, 'CR0009', 'ID_DOCUMENT', NULL, 'pass', '');
INSERT INTO client_authentication_method VALUES (1018, 'CR0010', 'PHONE_NUMBER', '2008-12-30 08:48:00', 'pass', '989125707281');
INSERT INTO client_authentication_method VALUES (1038, 'CR0011', 'PHONE_NUMBER', '2009-07-22 06:08:00', 'pass', '5689565695');
INSERT INTO client_authentication_method VALUES (1058, 'CR0012', 'PHONE_NUMBER', '2009-02-25 09:41:00', 'pass', '60122373211');
INSERT INTO client_authentication_method VALUES (1078, 'CR0012', 'ADDRESS', '2009-02-23 00:00:00', 'pending', 'address   tiwn 12341 Indonesia');
INSERT INTO client_authentication_method VALUES (1118, 'CR0013', 'PHONE_NUMBER', '2009-08-13 09:35:00', 'pass', '611234567');
INSERT INTO client_authentication_method VALUES (1138, 'CR0013', 'ADDRESS', '2009-08-13 00:00:00', 'pending', 'test test   test 12345 Australia');
INSERT INTO client_authentication_method VALUES (1178, 'CR0014', 'PHONE_NUMBER', '2009-08-13 10:03:00', 'pass', '611234549');
INSERT INTO client_authentication_method VALUES (1198, 'CR0014', 'ADDRESS', '2009-08-13 00:00:00', 'pending', 'test test   test 11111 Australia');
INSERT INTO client_authentication_method VALUES (1238, 'CR0015', 'PHONE_NUMBER', '2009-08-31 10:03:00', 'pass', '611234549');
INSERT INTO client_authentication_method VALUES (1258, 'CR0015', 'ADDRESS', '2009-08-31 00:00:00', 'pending', 'test test   test 11111 Australia');
INSERT INTO client_authentication_method VALUES (1298, 'CR0016', 'PHONE_NUMBER', '2009-07-31 10:03:00', 'pass', '611234549');
INSERT INTO client_authentication_method VALUES (1318, 'CR0016', 'ADDRESS', '2009-07-31 00:00:00', 'pending', 'test test   test 11111 Australia');
INSERT INTO client_authentication_method VALUES (1338, 'CR0017', 'PHONE_NUMBER', '2009-09-10 04:06:00', 'pass', '611234556');
INSERT INTO client_authentication_method VALUES (1358, 'CR0017', 'ADDRESS', '2009-08-19 00:00:00', 'pass', 'test test   test 12345 Australia');
INSERT INTO client_authentication_method VALUES (1378, 'CR0017', 'ID_DOCUMENT', NULL, 'pass', '');
INSERT INTO client_authentication_method VALUES (1398, 'CR0020', 'PHONE_NUMBER', '2009-07-22 06:08:00', 'pass', '5689565695');
INSERT INTO client_authentication_method VALUES (1418, 'CR0021', 'PHONE_NUMBER', '2009-07-22 06:08:00', 'pass', '5689565695');
INSERT INTO client_authentication_method VALUES (1458, 'CR0026', 'PHONE_NUMBER', '2009-07-31 10:03:00', 'pass', '611234549');
INSERT INTO client_authentication_method VALUES (1478, 'CR0026', 'ADDRESS', '2009-07-31 00:00:00', 'pending', 'test test   test 11111 Australia');
INSERT INTO client_authentication_method VALUES (1518, 'CR0027', 'PHONE_NUMBER', '2009-07-31 10:03:00', 'pass', '611234549');
INSERT INTO client_authentication_method VALUES (1538, 'CR0027', 'ADDRESS', '2009-07-31 00:00:00', 'pending', 'test test   test 11111 Australia');
INSERT INTO client_authentication_method VALUES (1578, 'CR0028', 'PHONE_NUMBER', '2009-11-18 10:03:00', 'pass', '6712345678');
INSERT INTO client_authentication_method VALUES (1598, 'CR0028', 'ADDRESS', '2009-11-18 00:00:00', 'pending', 'Igloo 1 Polar street   Bearcity 11111 Antarctica');
INSERT INTO client_authentication_method VALUES (1638, 'CR0029', 'PHONE_NUMBER', '2009-11-18 10:03:00', 'pass', '6712345678');
INSERT INTO client_authentication_method VALUES (1658, 'CR0029', 'ADDRESS', '2009-11-18 00:00:00', 'pending', 'Igloo 1 Polar street   Bearcity 11111 Antarctica');
INSERT INTO client_authentication_method VALUES (1698, 'CR0030', 'PHONE_NUMBER', '2009-11-18 10:03:00', 'pass', '6712345678');
INSERT INTO client_authentication_method VALUES (1718, 'CR0030', 'ADDRESS', '2009-11-18 00:00:00', 'pending', 'Igloo 1 Polar street   Bearcity 11111 Antarctica');
INSERT INTO client_authentication_method VALUES (1738, 'CR0031', 'PHONE_NUMBER', '2009-03-20 02:10:00', 'pass', '00869145685792');
INSERT INTO client_authentication_method VALUES (1758, 'CR0031', 'ADDRESS', '2010-01-19 00:00:00', 'pass', 'NING BO, CHINA');
INSERT INTO client_authentication_method VALUES (1778, 'CR0031', 'ID_DOCUMENT', NULL, 'pass', '');
INSERT INTO client_authentication_method VALUES (1898, 'CR0009', 'ADDRESS', '2010-05-12 06:13:29', 'pass', 'NING BO, CHINA');
INSERT INTO client_authentication_method VALUES (2738, 'MLT0017', 'ID_DOCUMENT', '2010-05-12 06:21:37', 'pass', '');
INSERT INTO client_authentication_method VALUES (2678, 'MLT0017', 'ADDRESS', '2010-05-12 06:30:08', 'pending', '');


--
-- Data for Name: promo_code; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

INSERT INTO promo_code VALUES ('BOM2009', NULL, '2019-01-10 00:00:00', true, 'FREE_BET', '{"country":"ALL","currency":"ALL","amount":"20"}', 'Testing promocode');
INSERT INTO promo_code VALUES ('BOM-XY', NULL, '2015-01-30 00:00:00', true, 'GET_X_WHEN_DEPOSIT_Y', '{"country":"ALL","currency":"USD","amount":"100","min_deposit":"100"}', 'deposit');
INSERT INTO promo_code VALUES ('0013F10', NULL, '2020-01-10 00:00:00', true, 'FREE_BET', '{"country":"ALL","currency":"ALL","amount":"10"}', 'Subordinate affiliate testing promocode (username calum2, userid 13)');
INSERT INTO promo_code VALUES ('ABC123', NULL, '2019-01-10 00:00:00', true, 'FREE_BET', '{"min_turnover":"100","country":"ALL","currency":"USD","amount":"10"}', 'Testing promocode');


--
-- Data for Name: client_promo_code; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

INSERT INTO client_promo_code VALUES (258, 'MLT0013', 'BOM2009', NULL, 'CLAIM', '611234567', false);
INSERT INTO client_promo_code VALUES (318, 'MLT0014', 'BOM2009', NULL, 'CLAIM', '611234549', false);
INSERT INTO client_promo_code VALUES (378, 'MLT0015', 'BOM2009', NULL, 'CLAIM', '611234549', false);
INSERT INTO client_promo_code VALUES (438, 'MLT0016', 'BOM2009', NULL, 'CLAIM', '611234549', false);
INSERT INTO client_promo_code VALUES (538, 'MX0013', 'BOM2009', NULL, 'CLAIM', '611234567', false);
INSERT INTO client_promo_code VALUES (598, 'MX0014', 'BOM2009', NULL, 'CLAIM', '611234549', false);
INSERT INTO client_promo_code VALUES (658, 'MX0015', 'BOM2009', NULL, 'CLAIM', '611234549', false);
INSERT INTO client_promo_code VALUES (718, 'MX0016', 'BOM2009', NULL, 'CLAIM', '611234549', false);
INSERT INTO client_promo_code VALUES (1098, 'CR0013', 'BOM2009', NULL, 'CLAIM', '611234567', false);
INSERT INTO client_promo_code VALUES (1158, 'CR0014', 'BOM2009', NULL, 'CLAIM', '611234549', false);
INSERT INTO client_promo_code VALUES (1218, 'CR0015', 'BOM2009', NULL, 'CLAIM', '611234549', false);
INSERT INTO client_promo_code VALUES (1278, 'CR0016', 'BOM2009', NULL, 'CLAIM', '611234549', false);
INSERT INTO client_promo_code VALUES (1438, 'CR0026', 'BOM2009', NULL, 'CLAIM', '611234549', false);
INSERT INTO client_promo_code VALUES (1498, 'CR0027', '0013F10', NULL, 'CLAIM', '611234549', false);
INSERT INTO client_promo_code VALUES (1558, 'CR0028', 'BOM2009', NULL, 'CLAIM', '6712345678', false);
INSERT INTO client_promo_code VALUES (1618, 'CR0029', 'BOM-XY', NULL, 'CLAIM', '6712345678', false);
INSERT INTO client_promo_code VALUES (1678, 'CR0030', 'BOM-XY', NULL, 'CLAIM', '6712345678', false);
INSERT INTO client_promo_code VALUES (2118, 'CR0009', 'BOM-XY', NULL, 'CLAIM', '00869145685792', false);
INSERT INTO client_promo_code VALUES (3458, 'CR0011', 'BOM2009', '2010-05-12 06:40:11', 'NOT_CLAIM', '', false);
INSERT INTO client_promo_code VALUES (3600, 'CR2002', 'ABC123', '2014-01-01 06:40:11', 'CLAIM', '', false);


--
-- Data for Name: client_status; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

INSERT INTO client_status VALUES (1798, 'CR0008', 'unwelcome', 'system', 'use for testing', NULL);
INSERT INTO client_status VALUES (1818, 'CR0008', 'disabled', 'system', 'FOR TESTING', NULL);


--
-- Data for Name: payment_agent; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

INSERT INTO payment_agent VALUES ('CR0020', 'Paypal', 'http://yahoo.com', 'jys@my.regentmarkets.com', '987987987', 'paypal egold neteller and a lot more', 'iuhiuh', 0.100000001, 0.5, true, NULL, 'USD', '', '', 'GTBank');


--
-- Data for Name: self_exclusion; Type: TABLE DATA; Schema: betonmarkets; Owner: postgres
--

INSERT INTO self_exclusion VALUES ('CR0031', 31000, 2000, 15, '2014-11-25', 25, NULL);
INSERT INTO self_exclusion VALUES ('CR0009', 200000, 1000, 50, '2009-09-06', 20, NULL);


SET search_path = data_collection, pg_catalog;

--
-- Data for Name: exchange_rate; Type: TABLE DATA; Schema: data_collection; Owner: postgres
--

INSERT INTO exchange_rate VALUES (1099, 'USD', 'USD', '2001-01-01 00:00:00', 1.0000);
INSERT INTO exchange_rate VALUES (1119, 'GBP', 'USD', '2001-01-01 00:00:00', 1.6000);
INSERT INTO exchange_rate VALUES (1139, 'EUR', 'USD', '2001-01-01 00:00:00', 1.5000);
INSERT INTO exchange_rate VALUES (1159, 'AUD', 'USD', '2001-01-01 00:00:00', 0.9000);


SET search_path = payment, pg_catalog;

--
-- Data for Name: payment; Type: TABLE DATA; Schema: payment; Owner: postgres
--

INSERT INTO payment VALUES (12003, '2010-07-27 05:37:07', 1000.0000, 'doughflow', 'external_cashier', 'OK', 1203, 'test_staff', 'Sample!');
INSERT INTO payment VALUES (200019, '2011-01-01 08:00:00', 150.0000, 'legacy_payment', 'compacted_statement', 'OK', 200039, 'MX1001', 'Compacted statement prior to 01-Jan-11 08h00GMT; purchases=GBP100.00 sales=GBP50.00 deposits=GBP500.00 withdrawals=GBP200 purchases_intradaydoubles=GBP10 purchases_runbets=GBP80');
INSERT INTO payment VALUES (200039, '2011-03-09 06:22:00', 2000.0000, 'moneybookers', 'ewallet', 'OK', 200039, 'MX1001', 'Moneybookers deposit REF:MX100111271050920 ID:257054611 Email:ohoushyar@gmail.com Amount:GBP2000.00 Moneybookers Timestamp 9-Mar-11 05h44GMT');
INSERT INTO payment VALUES (200059, '2011-03-09 07:22:00', 2000.0000, 'legacy_payment', 'ewallet', 'OK', 200039, 'MX1001', 'sample remark 2');
INSERT INTO payment VALUES (200069, '2011-03-09 07:23:00', 100.0000, 'legacy_payment', 'ewallet', 'OK', 200039, 'MX1001', 'sample remark 3');
INSERT INTO payment VALUES (200070, '2011-03-09 07:24:00', 100.0000, 'legacy_payment', 'ewallet', 'OK', 200039, 'MX1001', 'sample remark 4');
INSERT INTO payment VALUES (200079, '2011-03-09 08:00:00', -100.0000, 'legacy_payment', 'ewallet', 'OK', 200039, 'MX1001', 'Neteller withdrawal to account 451724851552 Transaction id 4058036 to neteller a/c 451724851552 (request GBP 100 / received GBP 100)');
INSERT INTO payment VALUES (200159, '2009-08-13 09:35:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200099, 'CR5154', 'Free gift (claimed from mobile 611234567)');
INSERT INTO payment VALUES (200219, '2009-08-13 09:35:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200199, 'MLT5154', 'Free gift (claimed from mobile 611234567)');
INSERT INTO payment VALUES (200239, '2008-07-24 08:15:00', 5000.0000, 'legacy_payment', 'credit_debit_card', 'OK', 200219, 'CR0031', 'Credit Card Deposit visa');
INSERT INTO payment VALUES (200259, '2010-05-18 09:11:00', -100.0000, 'datacash', 'bacs', 'OK', 200219, 'CR0031', 'BACS withdrawal to bank account ::ecp::52616e646f6d495633363368676674791b651ae4a55c9cc38235c177ced55b71e55343376ac555f2 (USD100=GBP69.36) status=42');
INSERT INTO payment VALUES (200279, '2010-05-18 09:12:00', -100.0000, 'datacash', 'bacs', 'OK', 200219, 'CR0031', 'BACS withdrawal to bank account ::ecp::52616e646f6d495633363368676674791b651ae4a55c9cc3e5e28a7713e7cc12ee3ba61384d27e4e (USD100=GBP69.36) status=44');
INSERT INTO payment VALUES (200299, '2010-05-18 09:14:00', -100.0000, 'datacash', 'bacs', 'OK', 200219, 'CR0031', 'BACS withdrawal to bank account ::ecp::52616e646f6d495633363368676674791b651ae4a55c9cc3e5e28a7713e7cc12ee3ba61384d27e4e (USD100=GBP69.36) status=44');
INSERT INTO payment VALUES (200319, '2010-05-18 09:24:00', -100.0000, 'datacash', 'bacs', 'OK', 200219, 'CR0031', 'BACS withdrawal to bank account ::ecp::52616e646f6d495633363368676674791b651ae4a55c9cc3e5e28a7713e7cc12ee3ba61384d27e4e (USD100=GBP69.36) status=44');
INSERT INTO payment VALUES (200339, '2010-05-19 09:24:00', -100.0000, 'datacash', 'bacs', 'OK', 200219, 'CR0031', 'BACS withdrawal to bank account ::ecp::52616e646f6d495633363368676674791b651ae4a55c9cc3e5e28a7713e7cc12ee3ba61384d27e4e (USD100=GBP69.36) status=44');
INSERT INTO payment VALUES (200379, '2009-11-18 10:11:00', 6180.0000, 'bank_wire', 'bank_money_transfer', 'OK', 200259, 'geokkheng', 'Wire deposit from Sutrisno Suryoputro Received by RBSI 5880-58269864 on 18-Nov-09; Bank Ref#  46510567; Bank Name  HSBC Bank; Acct No  007-059066-081; Acct Name  Sutrisno Suryoputro');
INSERT INTO payment VALUES (200439, '2009-11-18 03:13:00', 100.0000, 'free_gift', 'free_gift', 'OK', 200259, 'CR0029', 'Free gift (claimed from mobile 611231242)');
INSERT INTO payment VALUES (200419, '2009-11-18 04:18:00', 500.0000, 'datacash', 'credit_debit_card', 'OK', 200279, 'CR0028', 'BLURB=datacash credit card deposit ORDERID=77516256288 (71516256288,) TIMESTAMP=18-Nov-09 04h18GMT');
INSERT INTO payment VALUES (200459, '2009-09-10 04:18:00', 1000.0000, 'datacash', 'credit_debit_card', 'OK', 200299, 'CR0016', 'BLURB=datacash credit card deposit ORDERID=77516256288 (77315256388,) TIMESTAMP=10-Sep-09 04h18GMT');
INSERT INTO payment VALUES (200499, '2009-11-18 04:18:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200279, 'CR0028', 'Free gift (claimed from mobile 6712345678) (4900200063643402,) TIMESTAMP=18-Nov-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS ');
INSERT INTO payment VALUES (200519, '2009-09-10 04:18:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200299, 'CR0016', 'Free gift (claimed from mobile 611234549) (4900200063643402,) TIMESTAMP=10-Sep-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS ');
INSERT INTO payment VALUES (200539, '2009-09-10 04:18:00', 100.0000, 'datacash', 'credit_debit_card', 'OK', 200319, 'CR0016', 'BLURB=datacash credit card deposit ORDERID=77516256288 (4900200063643402,) TIMESTAMP=10-Sep-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS');
INSERT INTO payment VALUES (200559, '2007-04-15 21:02:00', 10.0000, 'legacy_payment', 'ewallet', 'OK', 200339, 'CR0025', 'Egold deposit Batch 79320704 from egold ac 4312604 (0.014586 ounces of Gold at $685.60/ounce) Egold Ti$');
INSERT INTO payment VALUES (200599, '2005-09-21 06:14:00', 600.0000, 'legacy_payment', 'ewallet', 'OK', 200359, 'CR0021', 'Egold deposit Batch 49100734 from egold ac 2427854 (1.291156 ounces of Gold at $464.70/ounce) Egold Timestamp 1127283282');
INSERT INTO payment VALUES (200579, '2009-09-10 04:28:00', 200.0000, 'envoy_transfer', 'bank_money_transfer', 'OK', 200319, 'CR0016', 'Envoy deposit');
INSERT INTO payment VALUES (200619, '2007-04-16 01:53:00', 5.0000, 'legacy_payment', 'ewallet', 'OK', 200339, 'CR0025', 'Egold deposit Batch 79327577 from egold ac 4312604 (0.007308 ounces of Gold at $684.20/ounce) Egold Tim$');
INSERT INTO payment VALUES (200639, '2007-04-16 21:34:00', 5.0000, 'legacy_payment', 'ewallet', 'OK', 200339, 'CR0025', 'Egold deposit Batch 79375397 from egold ac 4312604 (0.007241 ounces of Gold at $690.50/ounce) Egold Tim$');
INSERT INTO payment VALUES (200659, '2009-09-10 04:18:00', 100.0000, 'datacash', 'credit_debit_card', 'OK', 200379, 'CR0016', 'BLURB=datacash credit card deposit ORDERID=77516256288 (4900200063643402,) TIMESTAMP=10-Sep-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS');
INSERT INTO payment VALUES (200679, '2009-09-10 04:28:00', 200.0000, 'envoy_transfer', 'bank_money_transfer', 'OK', 200379, 'CR0016', 'Envoy deposit');
INSERT INTO payment VALUES (200699, '2009-08-13 09:35:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200399, 'CR5154', 'Free gift (claimed from mobile 611234567)');
INSERT INTO payment VALUES (200719, '2007-07-24 08:15:00', 5000.0000, 'legacy_payment', 'credit_debit_card', 'OK', 200439, 'CR0009', 'Credit Card Deposit');
INSERT INTO payment VALUES (200739, '2008-07-24 08:15:00', 500000.0000, 'legacy_payment', 'credit_debit_card', 'OK', 200459, 'CR0008', 'Credit Card Deposit');
INSERT INTO payment VALUES (200759, '2008-07-24 08:15:00', 5.0000, 'free_gift', 'free_gift', 'OK', 200479, 'CR0006', 'Free gift (claimed from mobile 441234567890)');
INSERT INTO payment VALUES (200779, '2007-02-26 14:29:00', 404.0000, 'legacy_payment', 'ewallet', 'OK', 200499, 'CR0005', 'Egold deposit Batch 76721052 from egold ac 2387346 (0.587209 ounces of Gold at $688.00/ounce) Egold Timestamp 1172500146');
INSERT INTO payment VALUES (200799, '2009-07-31 06:03:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200519, 'CR0016', 'Free gift (claimed from mobile 611234549)');
INSERT INTO payment VALUES (200819, '2009-08-31 10:03:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200539, 'CR0015', 'Free gift (claimed from mobile 611234549)');
INSERT INTO payment VALUES (200839, '2009-07-31 07:10:00', 10000.0000, 'datacash', 'credit_debit_card', 'OK', 200519, 'CR0016', 'datacash credit card deposit ORDERID=77516059288 (71510466288,) TIMESTAMP=31-Jul-09 07h10GMT');
INSERT INTO payment VALUES (200859, '2009-08-13 09:52:00', 1000.0000, 'datacash', 'credit_debit_card', 'OK', 200559, 'CR5156', 'BLURB=datacash credit card deposit ORDERID=77515657112 (4800200063243697,) TIMESTAMP=13-Aug-09 09h52GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS');
INSERT INTO payment VALUES (200879, '2009-08-13 10:03:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200559, 'CR5156', 'Free gift (claimed from mobile 611234549)');
INSERT INTO payment VALUES (200899, '2009-07-31 06:03:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200579, 'MLT0016', 'Free gift (claimed from mobile 611234549)');
INSERT INTO payment VALUES (200919, '2009-07-31 07:10:00', 10000.0000, 'datacash', 'credit_debit_card', 'OK', 200579, 'MLT0016', 'datacash credit card deposit ORDERID=775178856288 (77285256348,) TIMESTAMP=31-Jul-09 07h10GMT');
INSERT INTO payment VALUES (200939, '2009-08-31 10:03:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200599, 'MLT0015', 'Free gift (claimed from mobile 611234549)');
INSERT INTO payment VALUES (200959, '2009-08-13 09:52:00', 1000.0000, 'datacash', 'credit_debit_card', 'OK', 200619, 'MLT5156', 'BLURB=datacash credit card deposit ORDERID=77515657112 (4800200063243697,) TIMESTAMP=13-Aug-09 09h52GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS');
INSERT INTO payment VALUES (200979, '2009-08-13 10:03:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200619, 'MLT5156', 'Free gift (claimed from mobile 611234549)');
INSERT INTO payment VALUES (200999, '2009-07-15 10:08:00', 100.0000, 'datacash', 'credit_debit_card', 'OK', 200639, 'CR0030', 'BLURB=datacash credit card deposit ORDERID=77705752425 (4500200062818819,) TIMESTAMP=15-Jul-09 10h08GMT CCHH F599A8A4628AA9284913028A352A4E1D V99042100 Delta 3DS');
INSERT INTO payment VALUES (201039, '2009-08-14 08:48:00', -100.0000, 'datacash', 'credit_debit_card', 'OK', 200639, 'CR0030', 'datacash credit card refund ');
INSERT INTO payment VALUES (201059, '2009-09-29 04:28:00', 15.0000, 'datacash', 'credit_debit_card', 'OK', 200639, 'CR0030', 'BLURB=datacash credit card deposit ORDERID=77705798535 (4000200063989450,617154) TIMESTAMP=29-Sep-09 04h28GMT CCHH 78674CF5D33148801E771563691DB08F (GBR) V99042100 VISA');
INSERT INTO payment VALUES (201079, '2009-09-29 04:30:00', 20.0000, 'datacash', 'credit_debit_card', 'OK', 200639, 'CR0030', 'BLURB=datacash credit card deposit ORDERID=77705798596 (4200200063989454,) TIMESTAMP=29-Sep-09 04h30GMT CCHH 78674CF5D33148801E771563691DB08F V99042100 VISA 3DS');
INSERT INTO payment VALUES (201099, '2009-07-31 06:03:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200679, 'CR0016', 'Free gift (claimed from mobile 611234549)');
INSERT INTO payment VALUES (201119, '2009-09-29 04:50:00', -15.0000, 'datacash', 'credit_debit_card', 'OK', 200639, 'CR0030', 'datacash credit card refund 4600200063989640 967473 1254199822 V99042100');
INSERT INTO payment VALUES (201139, '2009-07-31 06:03:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200699, 'CR0016', 'Free gift (claimed from mobile 611234549)');
INSERT INTO payment VALUES (201159, '2009-07-31 07:10:00', 10000.0000, 'datacash', 'credit_debit_card', 'OK', 200679, 'CR0016', 'datacash credit card deposit ORDERID=775178256288 (77385256388,) TIMESTAMP=31-Jul-09 07h10GMT');
INSERT INTO payment VALUES (201179, '2009-09-29 05:52:00', 1000.0000, 'datacash', 'credit_debit_card', 'OK', 200639, 'CR0030', 'BLURB=datacash credit card deposit ORDERID=77705703569 (4200200063989982,817312) TIMESTAMP=29-Sep-09 05h52GMT CCHH 74B32F131EE301ED2D819D443CB718E6 (GBR) V99042100 VISA');
INSERT INTO payment VALUES (201199, '2009-07-31 07:10:00', 10000.0000, 'datacash', 'credit_debit_card', 'OK', 200699, 'CR0016', 'datacash credit card deposit ORDERID=775178256287 (77385256387,) TIMESTAMP=31-Jul-09 07h10GMT');
INSERT INTO payment VALUES (201219, '2009-09-29 05:58:00', -100.0000, 'datacash', 'credit_debit_card', 'OK', 200639, 'CR0030', 'datacash credit card refund 4800200063990020 755771 1254203935 V99042100');
INSERT INTO payment VALUES (201239, '2009-10-06 08:08:00', -100.0000, 'datacash', 'credit_debit_card', 'OK', 200639, 'CR0030', 'datacash credit card refund 4300200064129453 514447 1254816486 V99042100');
INSERT INTO payment VALUES (201279, '2009-09-10 04:18:00', 100.0000, 'datacash', 'credit_debit_card', 'OK', 200739, 'CR5162', 'BLURB=datacash credit card deposit ORDERID=77516256288 (4900200063643402,) TIMESTAMP=10-Sep-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS');
INSERT INTO payment VALUES (201299, '2009-09-10 04:28:00', 200.0000, 'envoy_transfer', 'bank_money_transfer', 'OK', 200739, 'CR5162', 'Envoy deposit');
INSERT INTO payment VALUES (201359, '2009-08-31 10:03:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200779, 'CR0015', 'Free gift (claimed from mobile 611234549)');
INSERT INTO payment VALUES (201379, '2009-08-13 09:52:00', 1000.0000, 'datacash', 'credit_debit_card', 'OK', 200799, 'CR0014', 'BLURB=datacash credit card deposit ORDERID=77515657112 (4800200063243697,) TIMESTAMP=13-Aug-09 09h52GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS');
INSERT INTO payment VALUES (201399, '2009-08-13 10:03:00', 20.0000, 'free_gift', 'free_gift', 'OK', 200799, 'CR0014', 'Free gift (claimed from mobile 611234549)');
INSERT INTO payment VALUES (201459, '2007-02-24 13:53:00', 10000.0000, 'legacy_payment', 'ewallet', 'OK', 200859, 'MLT16143', 'Egold deposit Batch 76627601 from egold ac 3113268 (0.153711 ounces of Gold at $683.10/ounce) Egold Timestamp 1172325220');
INSERT INTO payment VALUES (201519, '2008-01-15 13:41:00', -50.0000, 'legacy_payment', 'ewallet', 'OK', 200859, 'MLT16143', 'E-bullion withdrawal from MLT16143 to account D55032 Transaction id A44674209-MXP Timestamp 1200404467 (exchange 1)');
INSERT INTO payment VALUES (201559, '2008-01-18 17:33:00', -10.0000, 'legacy_payment', 'ewallet', 'OK', 200859, 'MLT16143', 'E-bullion withdrawal from MLT16143 to account D55032 Transaction id A76324677-MXP Timestamp 1200677631 (exchange 1)');
INSERT INTO payment VALUES (201579, '2008-01-21 15:37:00', -10.0000, 'legacy_payment', 'ewallet', 'OK', 200859, 'MLT16143', 'E-bullion withdrawal from MLT16143 to account D55032 Transaction id A98323624-MXP Timestamp 1200929831 (exchange 1)');
INSERT INTO payment VALUES (201599, '2007-02-12 07:54:00', 10000.0000, 'legacy_payment', 'cancellation', 'OK', 1202, 'CR7057', '');
INSERT INTO payment VALUES (201659, '2005-12-19 01:21:00', 5.0400, 'affiliate_reward', 'affiliate_reward', 'OK', 200919, 'AFFILIATE', 'Reward from affiliate program from 1-Sep-09 to 30-Sep-09');
INSERT INTO payment VALUES (201679, '2005-12-19 01:21:00', 5.0400, 'affiliate_reward', 'affiliate_reward', 'OK', 200939, 'AFFILIATE', 'Reward from affiliate program from 1-Sep-09 to 30-Sep-09');
INSERT INTO payment VALUES (201759, '2011-02-18 07:32:00', 20.0000, 'transactium_credit_debit_card', 'credit_debit_card', 'OK', 201039, 'CR0099', 'BLURB=transactium credit card deposit ORDERID=772068947928 (916594) TIMESTAMP=18-Feb-11 07h32GMT CCHH 12B361B3CD9E31A7C6012E13AD9BBD0A VISA');
INSERT INTO payment VALUES (201799, '2011-06-28 10:07:00', 10.0000, 'moneta', 'ewallet', 'OK', 201079, 'CR2002', 'Moneta deposit ExternalID:CR798051270634820 TransactionID:2628125 AccountNo:93617556 CorrespondingAccountNo:93617556 Amount:USD10.00 Moneta Timestamp 28-Jun-11 10:07:49GMT');


SET search_path = transaction, pg_catalog;

--
-- Data for Name: transaction; Type: TABLE DATA; Schema: transaction; Owner: postgres
--

INSERT INTO transaction VALUES (200019, 200039, '2011-01-01 08:00:00', 150.0000, 'MX1001', NULL, 'payment', NULL, 200019, 'deposit', 1);
INSERT INTO transaction VALUES (200039, 200039, '2011-03-09 06:22:00', 2000.0000, 'MX1001', NULL, 'payment', NULL, 200039, 'deposit', 1);
INSERT INTO transaction VALUES (200049, 200039, '2011-03-09 07:22:00', 2000.0000, 'MX1001', NULL, 'payment', NULL, 200059, 'deposit', 1);
INSERT INTO transaction VALUES (200050, 200039, '2011-03-09 07:23:00', 100.0000, 'MX1001', NULL, 'payment', NULL, 200069, 'deposit', 1);
INSERT INTO transaction VALUES (200051, 200039, '2011-03-09 07:24:00', 100.0000, 'MX1001', NULL, 'payment', NULL, 200070, 'deposit', 1);
INSERT INTO transaction VALUES (200059, 200039, '2011-03-09 07:25:00', -5.2000, 'MX1001', NULL, 'financial_market_bet', 200039, NULL, 'buy', 1);
INSERT INTO transaction VALUES (200079, 200039, '2011-03-09 07:25:00', -53.7500, 'MX1001', NULL, 'financial_market_bet', 200059, NULL, 'buy', 1);
INSERT INTO transaction VALUES (200099, 200039, '2011-03-09 08:00:00', -100.0000, 'MX1001', NULL, 'payment', NULL, 200079, 'withdrawal', 1);
INSERT INTO transaction VALUES (200179, 200099, '2009-08-13 09:35:00', 20.0000, 'CR5154', NULL, 'payment', NULL, 200159, 'deposit', 1);
INSERT INTO transaction VALUES (200279, 200099, '2009-08-14 07:19:00', -15.0400, 'CR0013', NULL, 'financial_market_bet', 200139, NULL, 'buy', 1);
INSERT INTO transaction VALUES (200339, 200099, '2009-08-14 07:21:00', 0.0000, 'CR0013', NULL, 'financial_market_bet', 200139, NULL, 'sell', 1);
INSERT INTO transaction VALUES (200499, 200199, '2009-08-13 09:35:00', 20.0000, 'MLT5154', NULL, 'payment', NULL, 200219, 'deposit', 1);
INSERT INTO transaction VALUES (200539, 200199, '2009-08-14 07:19:00', -15.0400, 'MLT0013', NULL, 'financial_market_bet', 200379, NULL, 'buy', 1);
INSERT INTO transaction VALUES (200599, 200199, '2009-08-14 07:21:00', 0.0000, 'MLT0013', NULL, 'financial_market_bet', 200379, NULL, 'sell', 1);
INSERT INTO transaction VALUES (200679, 200219, '2008-07-24 08:15:00', 5000.0000, 'CR0031', NULL, 'payment', NULL, 200239, 'deposit', 1);
INSERT INTO transaction VALUES (200719, 200219, '2010-05-18 09:11:00', -100.0000, 'CR0031', NULL, 'payment', NULL, 200259, 'withdrawal', 1);
INSERT INTO transaction VALUES (200779, 200219, '2010-05-18 09:12:00', -100.0000, 'CR0031', NULL, 'payment', NULL, 200279, 'withdrawal', 1);
INSERT INTO transaction VALUES (200839, 200219, '2010-05-18 09:14:00', -100.0000, 'CR0031', NULL, 'payment', NULL, 200299, 'withdrawal', 1);
INSERT INTO transaction VALUES (200899, 200219, '2010-05-18 09:24:00', -100.0000, 'CR0031', NULL, 'payment', NULL, 200319, 'withdrawal', 1);
INSERT INTO transaction VALUES (200959, 200219, '2010-05-19 09:24:00', -100.0000, 'CR0031', NULL, 'payment', NULL, 200339, 'withdrawal', 1);
INSERT INTO transaction VALUES (201039, 200259, '2009-11-18 10:11:00', 6180.0000, 'geokkheng', NULL, 'payment', NULL, 200379, 'deposit', 1);
INSERT INTO transaction VALUES (201079, 200259, '2009-11-18 03:13:00', 100.0000, 'CR0029', NULL, 'payment', NULL, 200439, 'deposit', 1);
INSERT INTO transaction VALUES (201099, 200279, '2009-11-18 04:18:00', 500.0000, 'CR0028', NULL, 'payment', NULL, 200419, 'deposit', 1);
INSERT INTO transaction VALUES (201139, 200299, '2009-09-10 04:18:00', 1000.0000, 'CR0016', NULL, 'payment', NULL, 200459, 'deposit', 1);
INSERT INTO transaction VALUES (201179, 200279, '2009-11-18 04:18:00', 20.0000, 'CR0028', NULL, 'payment', NULL, 200499, 'deposit', 1);
INSERT INTO transaction VALUES (201199, 200299, '2009-09-10 04:18:00', 20.0000, 'CR0016', NULL, 'payment', NULL, 200519, 'deposit', 1);
INSERT INTO transaction VALUES (201239, 200279, '2009-11-18 08:46:00', -30.0000, 'CR0028', NULL, 'financial_market_bet', 200439, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201259, 200299, '2009-10-20 08:46:00', -300.0000, 'CR0016', NULL, 'financial_market_bet', 200459, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201279, 200279, '2009-11-18 02:07:00', 0.0000, 'CR0028', NULL, 'financial_market_bet', 200439, NULL, 'sell', 1);
INSERT INTO transaction VALUES (201319, 200299, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 200459, NULL, 'sell', 1);
INSERT INTO transaction VALUES (201359, 200319, '2009-09-10 04:18:00', 100.0000, 'CR0016', NULL, 'payment', NULL, 200539, 'deposit', 1);
INSERT INTO transaction VALUES (201399, 200359, '2005-09-21 06:14:00', 600.0000, 'CR0021', NULL, 'payment', NULL, 200599, 'deposit', 1);
INSERT INTO transaction VALUES (201439, 200359, '2005-09-21 06:16:00', -5.0000, 'CR0021', NULL, 'financial_market_bet', 200499, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201499, 200359, '2005-09-21 06:16:00', 9.5000, 'CR0021', NULL, 'financial_market_bet', 200499, NULL, 'sell', 1);
INSERT INTO transaction VALUES (201559, 200359, '2005-09-21 06:16:00', -5.0000, 'CR0021', NULL, 'financial_market_bet', 200599, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201659, 200359, '2005-09-21 06:16:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 200639, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201719, 200359, '2005-09-21 06:17:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 200639, NULL, 'sell', 1);
INSERT INTO transaction VALUES (201779, 200359, '2005-09-21 06:17:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 200739, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201839, 200359, '2005-09-21 06:17:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 200779, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201879, 200359, '2005-09-21 06:18:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 200799, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201939, 200359, '2005-09-21 06:18:00', 38.0000, 'CR0021', NULL, 'financial_market_bet', 200799, NULL, 'sell', 1);
INSERT INTO transaction VALUES (201979, 200359, '2005-09-21 06:18:00', -5.0000, 'CR0021', NULL, 'financial_market_bet', 200819, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202039, 200359, '2005-09-21 06:19:00', 9.5000, 'CR0021', NULL, 'financial_market_bet', 200819, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202119, 200359, '2005-09-21 06:19:00', -5.0000, 'CR0021', NULL, 'financial_market_bet', 200839, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202179, 200359, '2005-09-21 06:20:00', -15.0000, 'CR0021', NULL, 'financial_market_bet', 200879, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202219, 200359, '2005-09-21 06:20:00', 28.5000, 'CR0021', NULL, 'financial_market_bet', 200879, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202279, 200359, '2005-09-21 06:20:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 200939, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202339, 200359, '2005-09-21 06:21:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 200999, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202399, 200359, '2005-09-21 06:21:00', 38.0000, 'CR0021', NULL, 'financial_market_bet', 200999, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202439, 200359, '2005-09-21 06:21:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201059, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202479, 200359, '2005-09-21 06:21:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201059, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202539, 200359, '2005-09-21 06:22:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201099, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202579, 200359, '2005-09-21 06:22:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 201119, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202639, 200359, '2005-09-21 06:22:00', 38.0000, 'CR0021', NULL, 'financial_market_bet', 201119, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202679, 200359, '2005-09-21 06:22:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201139, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202739, 200359, '2005-09-21 06:23:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201139, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202799, 200359, '2005-09-21 06:23:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201199, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202859, 200359, '2005-09-21 06:24:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201199, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202899, 200359, '2005-09-21 06:24:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201259, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202959, 200359, '2005-09-21 06:24:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201259, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202979, 200359, '2005-09-21 06:24:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201299, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203019, 200359, '2005-09-21 06:24:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201299, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203059, 200359, '2005-09-21 06:24:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201339, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203099, 200359, '2005-09-21 06:25:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201379, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203139, 200359, '2005-09-21 06:25:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201419, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203159, 200359, '2005-09-21 06:25:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201419, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203179, 200359, '2005-09-21 06:26:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201439, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203199, 200359, '2005-09-21 06:26:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 201459, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203219, 200359, '2005-09-21 06:26:00', 38.0000, 'CR0021', NULL, 'financial_market_bet', 201459, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203239, 200359, '2005-09-21 06:27:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201479, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203259, 200359, '2005-09-21 06:27:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 201499, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203279, 200359, '2005-09-21 06:27:00', -40.0000, 'CR0021', NULL, 'financial_market_bet', 201519, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203299, 200359, '2005-09-21 06:27:00', 76.0000, 'CR0021', NULL, 'financial_market_bet', 201519, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203319, 200359, '2005-09-21 06:28:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201539, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203339, 200359, '2005-09-21 06:28:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201559, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203359, 200359, '2005-09-21 06:28:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201579, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203379, 200359, '2005-09-21 06:29:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 201599, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203399, 200359, '2005-09-21 06:29:00', 38.0000, 'CR0021', NULL, 'financial_market_bet', 201599, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203419, 200359, '2005-09-21 06:29:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201619, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203439, 200359, '2005-09-21 06:29:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201619, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203459, 200359, '2005-09-21 06:29:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201639, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203479, 200359, '2005-09-21 06:30:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 201659, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203499, 200359, '2005-09-21 06:30:00', 38.0000, 'CR0021', NULL, 'financial_market_bet', 201659, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203519, 200359, '2005-09-21 06:32:00', -25.0000, 'CR0021', NULL, 'financial_market_bet', 201679, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203539, 200359, '2005-09-21 06:33:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 201699, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203559, 200359, '2005-09-21 06:34:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 201719, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203579, 200359, '2005-09-21 06:34:00', -25.0000, 'CR0021', NULL, 'financial_market_bet', 201739, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203599, 200359, '2005-09-21 06:35:00', -25.0000, 'CR0021', NULL, 'financial_market_bet', 201759, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203619, 200359, '2005-09-21 06:36:00', -25.0000, 'CR0021', NULL, 'financial_market_bet', 201779, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203639, 200359, '2005-09-21 06:37:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 201799, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203659, 200359, '2005-09-21 06:37:00', -25.0000, 'CR0021', NULL, 'financial_market_bet', 201819, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203679, 200359, '2005-09-21 06:37:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201839, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203699, 200359, '2005-09-21 06:38:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201839, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203719, 200359, '2005-09-21 06:38:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201859, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203739, 200359, '2005-09-21 06:38:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201859, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203759, 200359, '2005-09-21 06:38:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201879, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203779, 200359, '2005-09-21 06:39:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201879, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203799, 200359, '2005-09-21 06:39:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201899, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201379, 200339, '2007-04-15 21:02:00', 10.0000, 'CR0025', NULL, 'payment', NULL, 200559, 'deposit', 1);
INSERT INTO transaction VALUES (201479, 200339, '2007-04-16 01:43:00', -5.0000, 'CR0025', NULL, 'financial_market_bet', 200519, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201539, 200339, '2007-04-16 01:48:00', -5.0000, 'CR0025', NULL, 'financial_market_bet', 200579, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201579, 200339, '2007-04-16 01:53:00', 5.0000, 'CR0025', NULL, 'payment', NULL, 200619, 'deposit', 1);
INSERT INTO transaction VALUES (201619, 200339, '2007-04-16 02:01:00', -5.0000, 'CR0025', NULL, 'financial_market_bet', 200659, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201699, 200339, '2007-04-16 02:33:00', 10.0000, 'CR0025', NULL, 'financial_market_bet', 200659, NULL, 'sell', 1);
INSERT INTO transaction VALUES (201759, 200339, '2007-04-16 20:18:00', 10.0000, 'CR0025', NULL, 'financial_market_bet', 200579, NULL, 'sell', 1);
INSERT INTO transaction VALUES (201819, 200339, '2007-04-16 21:34:00', 5.0000, 'CR0025', NULL, 'payment', NULL, 200639, 'deposit', 1);
INSERT INTO transaction VALUES (201919, 200339, '2007-04-16 21:38:00', 10.0000, 'CR0025', NULL, 'financial_market_bet', 200519, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202019, 200379, '2009-09-10 04:18:00', 100.0000, 'CR0016', NULL, 'payment', NULL, 200659, 'deposit', 1);
INSERT INTO transaction VALUES (202079, 200379, '2009-09-10 04:28:00', 200.0000, 'CR0016', NULL, 'payment', NULL, 200679, 'deposit', 1);
INSERT INTO transaction VALUES (202139, 200379, '2009-10-16 08:27:00', -1.1600, 'CR0016', NULL, 'financial_market_bet', 200859, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202199, 200379, '2009-10-20 08:46:00', -7.2600, 'CR0016', NULL, 'financial_market_bet', 200899, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202239, 200379, '2009-10-23 05:42:00', -1.0400, 'CR0016', NULL, 'financial_market_bet', 200919, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202299, 200379, '2009-10-23 05:43:00', -7.8000, 'CR0016', NULL, 'financial_market_bet', 200959, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202359, 200379, '2009-10-23 05:47:00', -7.8000, 'CR0016', NULL, 'financial_market_bet', 201019, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202419, 200379, '2009-10-23 05:50:00', -7.8000, 'CR0016', NULL, 'financial_market_bet', 201039, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202459, 200379, '2009-10-23 05:56:00', -7.8000, 'CR0016', NULL, 'financial_market_bet', 201079, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202519, 200379, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 200859, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202559, 200379, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 200899, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202599, 200379, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 200919, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202659, 200379, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 200959, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202719, 200379, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 201019, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202779, 200379, '2009-10-27 02:07:00', 15.0000, 'CR0016', NULL, 'financial_market_bet', 201039, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202839, 200379, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 201079, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202939, 200479, '2008-07-24 08:15:00', 5.0000, 'CR0006', NULL, 'payment', NULL, 200759, 'deposit', 1);
INSERT INTO transaction VALUES (201419, 200319, '2009-09-10 04:28:00', 200.0000, 'CR0016', NULL, 'payment', NULL, 200579, 'deposit', 1);
INSERT INTO transaction VALUES (201459, 200319, '2009-10-16 08:27:00', -1.1600, 'CR0016', NULL, 'financial_market_bet', 200539, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201519, 200319, '2009-10-20 08:46:00', -7.2600, 'CR0016', NULL, 'financial_market_bet', 200559, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201599, 200319, '2009-10-23 05:42:00', -1.0400, 'CR0016', NULL, 'financial_market_bet', 200619, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201639, 200319, '2009-10-23 05:43:00', -7.8000, 'CR0016', NULL, 'financial_market_bet', 200679, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201679, 200319, '2009-10-23 05:47:00', -7.8000, 'CR0016', NULL, 'financial_market_bet', 200699, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201739, 200319, '2009-10-23 05:50:00', -7.8000, 'CR0016', NULL, 'financial_market_bet', 200719, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201799, 200319, '2009-10-23 05:56:00', -7.8000, 'CR0016', NULL, 'financial_market_bet', 200759, NULL, 'buy', 1);
INSERT INTO transaction VALUES (201859, 200319, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 200539, NULL, 'sell', 1);
INSERT INTO transaction VALUES (201899, 200319, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 200559, NULL, 'sell', 1);
INSERT INTO transaction VALUES (201959, 200319, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 200619, NULL, 'sell', 1);
INSERT INTO transaction VALUES (201999, 200319, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 200679, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202059, 200319, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 200699, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202099, 200319, '2009-10-27 02:07:00', 15.0000, 'CR0016', NULL, 'financial_market_bet', 200719, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202159, 200319, '2009-10-27 02:07:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 200759, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202259, 200399, '2009-08-13 09:35:00', 20.0000, 'CR5154', NULL, 'payment', NULL, 200699, 'deposit', 1);
INSERT INTO transaction VALUES (202319, 200399, '2009-08-14 07:19:00', -15.0400, 'CR0013', NULL, 'financial_market_bet', 200979, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202379, 200399, '2009-08-14 07:21:00', 0.0000, 'CR0013', NULL, 'financial_market_bet', 200979, NULL, 'sell', 1);
INSERT INTO transaction VALUES (202499, 200439, '2007-07-24 08:15:00', 5000.0000, 'CR0009', NULL, 'payment', NULL, 200719, 'deposit', 1);
INSERT INTO transaction VALUES (202619, 200459, '2008-07-24 08:15:00', 500000.0000, 'CR0008', NULL, 'payment', NULL, 200739, 'deposit', 1);
INSERT INTO transaction VALUES (202699, 200459, '2009-04-27 02:24:00', -142.1000, 'CR0005', NULL, 'financial_market_bet', 201159, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202759, 200459, '2009-04-27 02:24:00', -15001.0000, 'CR0005', NULL, 'financial_market_bet', 201179, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202819, 200459, '2009-04-27 03:45:00', -15000.0000, 'CR0008', NULL, 'financial_market_bet', 201219, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202879, 200459, '2009-04-27 03:55:00', -1.0000, 'CR0008', NULL, 'financial_market_bet', 201239, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202919, 200459, '2009-04-27 05:58:00', -500.0000, 'CR0008', NULL, 'financial_market_bet', 201279, NULL, 'buy', 1);
INSERT INTO transaction VALUES (202999, 200499, '2007-02-26 14:29:00', 404.0000, 'CR0005', NULL, 'payment', NULL, 200779, 'deposit', 1);
INSERT INTO transaction VALUES (203039, 200499, '2007-02-27 02:24:00', -142.1000, 'CR0005', NULL, 'financial_market_bet', 201319, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203079, 200499, '2007-02-27 02:24:00', -125.1000, 'CR0005', NULL, 'financial_market_bet', 201359, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203119, 200499, '2007-02-27 03:45:00', 0.0000, 'CR0005', NULL, 'financial_market_bet', 201399, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203819, 200359, '2005-09-21 06:39:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201899, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203839, 200359, '2005-09-21 06:39:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201919, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203859, 200359, '2005-09-21 06:39:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201919, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203879, 200359, '2005-09-21 06:40:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201939, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203899, 200359, '2005-09-21 06:40:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201939, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203919, 200359, '2005-09-21 06:40:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201959, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203939, 200359, '2005-09-21 06:40:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 201979, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203959, 200359, '2005-09-21 06:40:00', 38.0000, 'CR0021', NULL, 'financial_market_bet', 201979, NULL, 'sell', 1);
INSERT INTO transaction VALUES (203979, 200359, '2005-09-21 06:40:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 201999, NULL, 'buy', 1);
INSERT INTO transaction VALUES (203999, 200359, '2005-09-21 06:41:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 201999, NULL, 'sell', 1);
INSERT INTO transaction VALUES (204019, 200359, '2005-09-21 06:41:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 202019, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204039, 200359, '2005-09-21 06:41:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 202019, NULL, 'sell', 1);
INSERT INTO transaction VALUES (204059, 200359, '2005-09-21 06:41:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 202039, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204079, 200359, '2005-09-21 06:41:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 202059, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204099, 200359, '2005-09-21 06:42:00', -40.0000, 'CR0021', NULL, 'financial_market_bet', 202079, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204119, 200359, '2005-09-21 06:42:00', -100.0000, 'CR0021', NULL, 'financial_market_bet', 202099, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204139, 200359, '2005-09-21 06:42:00', 190.0000, 'CR0021', NULL, 'financial_market_bet', 202099, NULL, 'sell', 1);
INSERT INTO transaction VALUES (204159, 200359, '2005-09-21 06:42:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 202119, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204179, 200359, '2005-09-21 06:42:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 202119, NULL, 'sell', 1);
INSERT INTO transaction VALUES (204199, 200359, '2005-09-21 06:43:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 202139, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204219, 200359, '2005-09-21 06:43:00', -20.0000, 'CR0021', NULL, 'financial_market_bet', 202159, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204239, 200359, '2005-09-21 06:43:00', -40.0000, 'CR0021', NULL, 'financial_market_bet', 202179, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204259, 200359, '2005-09-21 06:43:00', 76.0000, 'CR0021', NULL, 'financial_market_bet', 202179, NULL, 'sell', 1);
INSERT INTO transaction VALUES (204279, 200359, '2005-09-21 06:44:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 202199, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204299, 200359, '2005-09-21 06:44:00', 19.0000, 'CR0021', NULL, 'financial_market_bet', 202199, NULL, 'sell', 1);
INSERT INTO transaction VALUES (204319, 200359, '2005-09-21 06:44:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 202219, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204339, 200359, '2005-09-21 06:44:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 202239, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204359, 200359, '2005-09-21 06:45:00', -30.0000, 'CR0021', NULL, 'financial_market_bet', 202259, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204379, 200359, '2005-09-21 06:45:00', -50.0000, 'CR0021', NULL, 'financial_market_bet', 202279, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204399, 200359, '2005-09-21 06:45:00', -125.0000, 'CR0021', NULL, 'financial_market_bet', 202299, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204419, 200359, '2005-09-21 06:46:00', -125.0000, 'CR0021', NULL, 'financial_market_bet', 202319, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204439, 200359, '2005-09-21 06:46:00', 237.5000, 'CR0021', NULL, 'financial_market_bet', 202319, NULL, 'sell', 1);
INSERT INTO transaction VALUES (204459, 200359, '2005-09-21 06:46:00', -10.0000, 'CR0021', NULL, 'financial_market_bet', 202339, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204479, 200519, '2009-07-31 06:03:00', 20.0000, 'CR0016', NULL, 'payment', NULL, 200799, 'deposit', 1);
INSERT INTO transaction VALUES (204499, 200539, '2009-08-31 10:03:00', 20.0000, 'CR0015', NULL, 'payment', NULL, 200819, 'deposit', 1);
INSERT INTO transaction VALUES (204519, 200519, '2009-07-31 07:10:00', 10000.0000, 'CR0016', NULL, 'payment', NULL, 200839, 'deposit', 1);
INSERT INTO transaction VALUES (204539, 200559, '2009-08-13 09:52:00', 1000.0000, 'CR5156', NULL, 'payment', NULL, 200859, 'deposit', 1);
INSERT INTO transaction VALUES (204559, 200519, '2009-07-31 08:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202359, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204579, 200559, '2009-08-13 10:03:00', 20.0000, 'CR5156', NULL, 'payment', NULL, 200879, 'deposit', 1);
INSERT INTO transaction VALUES (204599, 200579, '2009-07-31 06:03:00', 20.0000, 'MLT0016', NULL, 'payment', NULL, 200899, 'deposit', 1);
INSERT INTO transaction VALUES (204619, 200519, '2009-07-31 23:48:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 202359, NULL, 'sell', 1);
INSERT INTO transaction VALUES (204639, 200579, '2009-07-31 07:10:00', 10000.0000, 'MLT0016', NULL, 'payment', NULL, 200919, 'deposit', 1);
INSERT INTO transaction VALUES (204659, 200559, '2009-08-13 12:00:00', -376.0000, 'CR00022', NULL, 'financial_market_bet', 202379, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204679, 200599, '2009-08-31 10:03:00', 20.0000, 'MLT0015', NULL, 'payment', NULL, 200939, 'deposit', 1);
INSERT INTO transaction VALUES (204699, 200579, '2009-07-31 08:21:00', -3140.0000, 'MLT0016', NULL, 'financial_market_bet', 202399, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204719, 200559, '2009-08-13 12:03:00', -396.9000, 'CR00022', NULL, 'financial_market_bet', 202419, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204739, 200579, '2009-07-31 23:48:00', 0.0000, 'MLT0016', NULL, 'financial_market_bet', 202399, NULL, 'sell', 1);
INSERT INTO transaction VALUES (204759, 200619, '2009-08-13 09:52:00', 1000.0000, 'MLT5156', NULL, 'payment', NULL, 200959, 'deposit', 1);
INSERT INTO transaction VALUES (204779, 200619, '2009-08-13 10:03:00', 20.0000, 'MLT5156', NULL, 'payment', NULL, 200979, 'deposit', 1);
INSERT INTO transaction VALUES (204799, 200639, '2009-07-15 10:08:00', 100.0000, 'CR0030', NULL, 'payment', NULL, 200999, 'deposit', 1);
INSERT INTO transaction VALUES (204839, 200639, '2009-08-14 08:48:00', -100.0000, 'CR0030', NULL, 'payment', NULL, 201039, 'withdrawal', 1);
INSERT INTO transaction VALUES (204859, 200619, '2009-08-13 12:00:00', -376.0000, 'MLT00022', NULL, 'financial_market_bet', 202439, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204899, 200639, '2009-09-29 04:28:00', 15.0000, 'CR0030', NULL, 'payment', NULL, 201059, 'deposit', 1);
INSERT INTO transaction VALUES (204919, 200619, '2009-08-13 12:03:00', -396.9000, 'MLT00022', NULL, 'financial_market_bet', 202479, NULL, 'buy', 1);
INSERT INTO transaction VALUES (204959, 200639, '2009-09-29 04:30:00', 20.0000, 'CR0030', NULL, 'payment', NULL, 201079, 'deposit', 1);
INSERT INTO transaction VALUES (204979, 200679, '2009-07-31 06:03:00', 20.0000, 'CR0016', NULL, 'payment', NULL, 201099, 'deposit', 1);
INSERT INTO transaction VALUES (204999, 200639, '2009-09-29 04:50:00', -15.0000, 'CR0030', NULL, 'payment', NULL, 201119, 'withdrawal', 1);
INSERT INTO transaction VALUES (205019, 200699, '2009-07-31 06:03:00', 20.0000, 'CR0016', NULL, 'payment', NULL, 201139, 'deposit', 1);
INSERT INTO transaction VALUES (205039, 200679, '2009-07-31 07:10:00', 10000.0000, 'CR0016', NULL, 'payment', NULL, 201159, 'deposit', 1);
INSERT INTO transaction VALUES (205059, 200639, '2009-09-29 05:52:00', 1000.0000, 'CR0030', NULL, 'payment', NULL, 201179, 'deposit', 1);
INSERT INTO transaction VALUES (205079, 200699, '2009-07-31 07:10:00', 10000.0000, 'CR0016', NULL, 'payment', NULL, 201199, 'deposit', 1);
INSERT INTO transaction VALUES (205099, 200679, '2009-07-31 08:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202499, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205119, 200699, '2009-07-31 08:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202519, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205139, 200639, '2009-09-29 05:53:00', -5.0000, 'CR0030', NULL, 'financial_market_bet', 202539, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205159, 200679, '2009-07-31 10:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202499, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205179, 200699, '2009-07-31 10:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202519, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205199, 200639, '2009-09-29 05:58:00', -100.0000, 'CR0030', NULL, 'payment', NULL, 201219, 'withdrawal', 1);
INSERT INTO transaction VALUES (205219, 200679, '2009-07-31 11:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202559, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205279, 200679, '2009-07-31 12:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202559, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205339, 200679, '2009-07-31 13:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202619, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205399, 200679, '2009-07-31 14:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202619, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205459, 200679, '2009-07-31 15:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202659, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205539, 200679, '2009-07-31 16:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202659, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205599, 200679, '2009-07-31 17:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202739, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205659, 200679, '2009-07-31 18:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202739, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205719, 200679, '2009-07-31 19:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202819, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205779, 200679, '2009-07-31 20:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202819, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205839, 200679, '2009-07-31 21:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202879, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205899, 200679, '2009-07-31 22:48:00', 0.0000, 'CR0016', NULL, 'financial_market_bet', 202879, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205959, 200679, '2009-07-31 23:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202919, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206019, 200679, '2009-07-31 23:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202919, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206079, 200679, '2009-07-31 23:49:00', -10.0000, 'CR0016', NULL, 'financial_market_bet', 202979, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206139, 200679, '2009-07-31 23:49:00', 19.0000, 'CR0016', NULL, 'financial_market_bet', 202979, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206199, 200739, '2009-09-10 04:18:00', 100.0000, 'CR5162', NULL, 'payment', NULL, 201279, 'deposit', 1);
INSERT INTO transaction VALUES (206259, 200739, '2009-09-10 04:28:00', 200.0000, 'CR5162', NULL, 'payment', NULL, 201299, 'deposit', 1);
INSERT INTO transaction VALUES (205239, 200699, '2009-07-31 11:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202579, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205299, 200699, '2009-07-31 12:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202579, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205359, 200699, '2009-07-31 13:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202639, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205419, 200699, '2009-07-31 14:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202639, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205479, 200699, '2009-07-31 15:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202679, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205519, 200699, '2009-07-31 16:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202679, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205579, 200699, '2009-07-31 17:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202719, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205639, 200699, '2009-07-31 18:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202719, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205699, 200699, '2009-07-31 19:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202799, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205759, 200699, '2009-07-31 20:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202799, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205819, 200699, '2009-07-31 21:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202859, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205879, 200699, '2009-07-31 22:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202859, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205919, 200699, '2009-07-31 23:21:00', -3140.0000, 'CR0016', NULL, 'financial_market_bet', 202899, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205979, 200699, '2009-07-31 23:48:00', 10000.0000, 'CR0016', NULL, 'financial_market_bet', 202899, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206039, 200699, '2009-07-31 23:49:00', -10.0000, 'CR0016', NULL, 'financial_market_bet', 202959, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206099, 200699, '2009-07-31 23:49:00', 19.0000, 'CR0016', NULL, 'financial_market_bet', 202959, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206419, 200779, '2009-08-31 10:03:00', 20.0000, 'CR0015', NULL, 'payment', NULL, 201359, 'deposit', 1);
INSERT INTO transaction VALUES (206479, 200799, '2009-08-13 09:52:00', 1000.0000, 'CR0014', NULL, 'payment', NULL, 201379, 'deposit', 1);
INSERT INTO transaction VALUES (206539, 200799, '2009-08-13 10:03:00', 20.0000, 'CR0014', NULL, 'payment', NULL, 201399, 'deposit', 1);
INSERT INTO transaction VALUES (206599, 200799, '2009-08-13 12:00:00', -376.0000, 'CR0014', NULL, 'financial_market_bet', 203179, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206659, 200799, '2009-08-13 12:03:00', -396.9000, 'CR0014', NULL, 'financial_market_bet', 203219, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206719, 200799, '2009-11-09 09:59:00', -46.8000, 'CR0014', NULL, 'financial_market_bet', 203239, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206779, 200799, '2009-11-09 10:00:00', 90.0000, 'CR0014', NULL, 'financial_market_bet', 203239, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205259, 200639, '2009-09-30 09:59:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 202539, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205319, 200639, '2009-09-30 10:20:00', -5.2100, 'CR0030', NULL, 'financial_market_bet', 202599, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205379, 200639, '2009-10-02 04:59:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 202599, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205439, 200639, '2009-10-06 08:08:00', -100.0000, 'CR0030', NULL, 'payment', NULL, 201239, 'withdrawal', 1);
INSERT INTO transaction VALUES (205499, 200639, '2009-10-07 04:00:00', -6.1300, 'CR0030', NULL, 'financial_market_bet', 202699, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205559, 200639, '2009-10-09 01:17:00', 10.0000, 'CR0030', NULL, 'financial_market_bet', 202699, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205619, 200639, '2009-11-03 07:14:00', -1.0400, 'CR0030', NULL, 'financial_market_bet', 202759, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205679, 200639, '2009-11-03 07:15:00', -10.8000, 'CR0030', NULL, 'financial_market_bet', 202779, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205739, 200639, '2009-11-03 07:17:00', -38.4700, 'CR0030', NULL, 'financial_market_bet', 202839, NULL, 'buy', 1);
INSERT INTO transaction VALUES (205799, 200639, '2009-11-04 10:40:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 202759, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205859, 200639, '2009-11-04 10:40:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 202779, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205939, 200639, '2009-11-04 10:40:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 202839, NULL, 'sell', 1);
INSERT INTO transaction VALUES (205999, 200639, '2009-11-04 10:41:00', -1.0400, 'CR0030', NULL, 'financial_market_bet', 202939, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206059, 200639, '2009-11-04 10:47:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 202939, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206119, 200639, '2009-11-05 02:25:00', -43.2600, 'CR0030', NULL, 'financial_market_bet', 202999, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206159, 200639, '2009-11-05 03:33:00', -1.0800, 'CR0030', NULL, 'financial_market_bet', 203019, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206219, 200639, '2009-11-05 05:19:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203019, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206279, 200639, '2009-11-05 05:46:00', -23.6600, 'CR0030', NULL, 'financial_market_bet', 203059, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206319, 200639, '2009-11-05 05:52:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203059, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206379, 200639, '2009-11-05 06:33:00', -9.7700, 'CR0030', NULL, 'financial_market_bet', 203099, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206439, 200639, '2009-11-05 06:34:00', -9.7700, 'CR0030', NULL, 'financial_market_bet', 203119, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206499, 200639, '2009-11-09 02:22:00', -32.4600, 'CR0030', NULL, 'financial_market_bet', 203159, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206559, 200639, '2009-11-09 04:57:00', 60.0000, 'CR0030', NULL, 'financial_market_bet', 203159, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206579, 200639, '2009-11-09 06:46:00', 40.0000, 'CR0030', NULL, 'financial_market_bet', 203099, NULL, 'sell', 2);
INSERT INTO transaction VALUES (206639, 200639, '2009-11-09 06:50:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203199, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206679, 200639, '2009-11-09 06:52:00', 20.0000, 'CR0030', NULL, 'financial_market_bet', 203199, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206739, 200639, '2009-11-09 06:52:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203259, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206799, 200639, '2009-11-09 06:54:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203259, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206839, 200639, '2009-11-09 09:59:00', -46.8000, 'CR0030', NULL, 'financial_market_bet', 203319, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206879, 200639, '2009-11-09 10:00:00', -46.8000, 'CR0030', NULL, 'financial_market_bet', 203359, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206899, 200639, '2009-11-09 10:00:00', 90.0000, 'CR0030', NULL, 'financial_market_bet', 203319, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206919, 200639, '2009-11-09 10:00:00', -46.8000, 'CR0030', NULL, 'financial_market_bet', 203379, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206939, 200639, '2009-11-09 10:01:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203359, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206959, 200639, '2009-11-09 10:01:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203379, NULL, 'sell', 1);
INSERT INTO transaction VALUES (206979, 200639, '2009-11-09 10:01:00', -48.6200, 'CR0030', NULL, 'financial_market_bet', 203399, NULL, 'buy', 1);
INSERT INTO transaction VALUES (206999, 200639, '2009-11-10 08:55:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203419, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207019, 200639, '2009-11-10 08:56:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203419, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207039, 200639, '2009-11-10 08:56:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203439, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207059, 200639, '2009-11-10 08:57:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203439, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207079, 200639, '2009-11-10 09:20:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203459, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207099, 200639, '2009-11-10 09:39:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203479, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207119, 200639, '2009-11-10 09:39:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203459, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207139, 200639, '2009-11-10 09:48:00', 20.0000, 'CR0030', NULL, 'financial_market_bet', 203479, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207159, 200639, '2009-11-10 09:48:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203499, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207179, 200639, '2009-11-10 09:50:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203499, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207199, 200639, '2009-11-10 09:50:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203519, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207219, 200639, '2009-11-10 09:55:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203539, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207239, 200639, '2009-11-10 09:55:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203519, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207259, 200639, '2009-11-10 09:56:00', 20.0000, 'CR0030', NULL, 'financial_market_bet', 203539, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207279, 200639, '2009-11-10 09:59:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203559, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207299, 200639, '2009-11-10 09:59:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203579, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207319, 200639, '2009-11-10 09:59:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203599, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207339, 200639, '2009-11-10 09:59:00', -10.4000, 'CR0030', NULL, 'financial_market_bet', 203619, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207359, 200639, '2009-11-11 01:56:00', -1.0400, 'CR0030', NULL, 'financial_market_bet', 203639, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207379, 200639, '2009-11-11 02:00:00', -1.0400, 'CR0030', NULL, 'financial_market_bet', 203659, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207399, 200639, '2009-11-11 02:34:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203599, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207419, 200639, '2009-11-11 02:34:00', 2.0000, 'CR0030', NULL, 'financial_market_bet', 203659, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207439, 200639, '2009-11-11 02:34:00', 2.0000, 'CR0030', NULL, 'financial_market_bet', 203639, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207459, 200639, '2009-11-11 02:34:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203619, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207479, 200639, '2009-11-11 02:34:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203579, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207499, 200639, '2009-11-11 02:34:00', 20.0000, 'CR0030', NULL, 'financial_market_bet', 203559, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207519, 200639, '2009-11-11 02:34:00', -1.0400, 'CR0030', NULL, 'financial_market_bet', 203679, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207539, 200639, '2009-11-11 02:35:00', 2.0000, 'CR0030', NULL, 'financial_market_bet', 203679, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207559, 200639, '2009-11-11 02:39:00', -1.0400, 'CR0030', NULL, 'financial_market_bet', 203699, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207579, 200639, '2009-11-11 02:39:00', -46.8000, 'CR0030', NULL, 'financial_market_bet', 203719, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207599, 200639, '2009-11-11 02:39:00', 2.0000, 'CR0030', NULL, 'financial_market_bet', 203699, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207619, 200639, '2009-11-11 02:41:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203719, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207639, 200639, '2009-11-11 07:50:00', -1.0400, 'CR0030', NULL, 'financial_market_bet', 203739, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207659, 200639, '2009-11-11 08:09:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203739, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207679, 200639, '2009-11-12 04:08:00', -1.0400, 'CR0030', NULL, 'financial_market_bet', 203759, NULL, 'buy', 1);
INSERT INTO transaction VALUES (207699, 200639, '2009-11-12 04:43:00', 0.0000, 'CR0030', NULL, 'financial_market_bet', 203759, NULL, 'sell', 1);
INSERT INTO transaction VALUES (207719, 200859, '2007-02-24 13:53:00', 10000.0000, 'MLT16143', NULL, 'payment', NULL, 201459, 'deposit', 1);
INSERT INTO transaction VALUES (207779, 200859, '2008-01-15 13:41:00', -50.0000, 'MLT16143', NULL, 'payment', NULL, 201519, 'withdrawal', 1);
INSERT INTO transaction VALUES (207839, 200859, '2008-01-18 17:33:00', -10.0000, 'MLT16143', NULL, 'payment', NULL, 201559, 'withdrawal', 1);
INSERT INTO transaction VALUES (207899, 200859, '2008-01-21 15:37:00', -10.0000, 'MLT16143', NULL, 'payment', NULL, 201579, 'withdrawal', 1);
INSERT INTO transaction VALUES (207979, 1202, '2007-02-12 07:54:00', 10000.0000, 'CR7057', NULL, 'payment', NULL, 201599, 'deposit', 1);
INSERT INTO transaction VALUES (208039, 1202, '2009-05-05 02:16:00', -25.0000, 'CR7057', NULL, 'financial_market_bet', 203899, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208099, 1202, '2009-05-05 02:18:00', -18.1000, 'CR7057', NULL, 'financial_market_bet', 203959, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208159, 1202, '2009-05-05 02:27:00', -25.0000, 'CR7057', NULL, 'financial_market_bet', 203999, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208219, 1202, '2009-05-05 02:32:00', -25.0000, 'CR7057', NULL, 'financial_market_bet', 204039, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208279, 1202, '2009-05-07 02:46:00', -25.0000, 'CR7057', NULL, 'financial_market_bet', 204079, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208339, 1202, '2009-05-07 09:55:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204099, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208399, 1202, '2009-05-07 09:55:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204139, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208459, 1202, '2009-05-07 09:56:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204159, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208519, 1202, '2009-05-07 09:58:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204199, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208579, 1202, '2009-05-08 02:16:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204219, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208639, 1202, '2009-05-08 02:20:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204259, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208679, 1202, '2009-05-08 02:20:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 203959, NULL, 'sell', 1);
INSERT INTO transaction VALUES (208719, 1202, '2009-05-08 02:22:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204299, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208759, 1202, '2009-05-08 02:22:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204099, NULL, 'sell', 1);
INSERT INTO transaction VALUES (208799, 1202, '2009-05-08 02:22:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204319, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208839, 1202, '2009-05-08 02:22:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204139, NULL, 'sell', 1);
INSERT INTO transaction VALUES (208879, 1202, '2009-05-08 02:49:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204359, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208919, 1202, '2009-05-08 02:49:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204159, NULL, 'sell', 1);
INSERT INTO transaction VALUES (208959, 1202, '2009-05-08 02:50:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204399, NULL, 'buy', 1);
INSERT INTO transaction VALUES (208999, 1202, '2009-05-08 02:50:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204199, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209039, 1202, '2009-05-08 02:52:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204439, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209079, 1202, '2009-05-08 02:52:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204219, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209119, 1202, '2009-05-08 02:59:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204479, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209159, 1202, '2009-05-08 02:59:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204259, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209199, 1202, '2009-05-08 03:03:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204519, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209239, 1202, '2009-05-08 03:03:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204299, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209279, 1202, '2009-05-08 03:06:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204559, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209319, 1202, '2009-05-08 03:06:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204319, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209379, 1202, '2009-05-08 03:07:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204619, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209419, 1202, '2009-05-08 03:07:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204359, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209459, 1202, '2009-05-08 03:08:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204659, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209499, 1202, '2009-05-08 03:08:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204399, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209539, 1202, '2009-05-08 03:08:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204699, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209579, 1202, '2009-05-08 03:08:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204439, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209619, 1202, '2009-05-08 03:42:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204739, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209659, 1202, '2009-05-08 03:42:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204479, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209699, 1202, '2009-05-08 03:47:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204799, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209739, 1202, '2009-05-08 03:47:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204519, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209779, 1202, '2009-05-08 03:47:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204839, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209819, 1202, '2009-05-08 03:47:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204559, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209859, 1202, '2009-05-08 03:55:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204879, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209899, 1202, '2009-05-08 03:55:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204619, NULL, 'sell', 1);
INSERT INTO transaction VALUES (209939, 1202, '2009-05-08 04:15:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204919, NULL, 'buy', 1);
INSERT INTO transaction VALUES (209979, 1202, '2009-05-08 04:15:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204659, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210019, 1202, '2009-05-08 04:18:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204959, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210059, 1202, '2009-05-08 04:18:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204699, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210099, 1202, '2009-05-08 04:19:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 204999, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210139, 1202, '2009-05-08 04:19:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204739, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210179, 1202, '2009-05-08 04:20:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205039, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210219, 1202, '2009-05-08 04:20:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204799, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210259, 1202, '2009-05-08 04:23:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205079, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210299, 1202, '2009-05-08 04:23:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204839, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210339, 1202, '2009-05-08 04:23:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205119, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210379, 1202, '2009-05-08 04:23:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204879, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210419, 1202, '2009-05-08 06:17:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205159, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210459, 1202, '2009-05-08 06:17:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204919, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210499, 1202, '2009-05-08 06:20:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205199, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210539, 1202, '2009-05-08 06:20:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204959, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210579, 1202, '2009-05-08 06:20:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205239, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210619, 1202, '2009-05-08 06:20:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 204999, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210659, 1202, '2009-05-08 06:26:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205279, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210699, 1202, '2009-05-08 06:26:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 205039, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210739, 1202, '2009-05-08 06:27:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205319, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210779, 1202, '2009-05-08 06:27:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 205079, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210819, 1202, '2009-05-08 06:28:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205359, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210859, 1202, '2009-05-08 06:28:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 205119, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210899, 1202, '2009-05-08 06:29:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205419, NULL, 'buy', 1);
INSERT INTO transaction VALUES (210939, 1202, '2009-05-08 06:29:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 205159, NULL, 'sell', 1);
INSERT INTO transaction VALUES (210979, 1202, '2009-05-08 06:30:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205459, NULL, 'buy', 1);
INSERT INTO transaction VALUES (211019, 1202, '2009-05-08 06:30:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 205199, NULL, 'sell', 1);
INSERT INTO transaction VALUES (211059, 1202, '2009-05-08 06:31:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205499, NULL, 'buy', 1);
INSERT INTO transaction VALUES (211099, 1202, '2009-05-08 06:31:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 205239, NULL, 'sell', 1);
INSERT INTO transaction VALUES (211139, 1202, '2009-05-08 06:36:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205539, NULL, 'buy', 1);
INSERT INTO transaction VALUES (211179, 1202, '2009-05-08 06:36:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 205279, NULL, 'sell', 1);
INSERT INTO transaction VALUES (211219, 1202, '2009-05-08 06:42:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205579, NULL, 'buy', 1);
INSERT INTO transaction VALUES (211259, 1202, '2009-05-08 06:42:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 205319, NULL, 'sell', 1);
INSERT INTO transaction VALUES (211299, 1202, '2009-05-08 06:43:00', -30.8200, 'CR0010', NULL, 'financial_market_bet', 205619, NULL, 'buy', 1);
INSERT INTO transaction VALUES (211339, 1202, '2009-05-08 06:43:00', 8.3200, 'CR0010', NULL, 'financial_market_bet', 205359, NULL, 'sell', 1);
INSERT INTO transaction VALUES (211679, 200919, '2005-12-19 01:21:00', 5.0400, 'AFFILIATE', NULL, 'payment', NULL, 201659, 'deposit', 1);
INSERT INTO transaction VALUES (211699, 200939, '2005-12-19 01:21:00', 5.0400, 'AFFILIATE', NULL, 'payment', NULL, 201679, 'deposit', 1);
INSERT INTO transaction VALUES (212059, 201039, '2011-02-18 07:32:00', 20.0000, 'CR0099', NULL, 'payment', NULL, 201759, 'deposit', 1);
INSERT INTO transaction VALUES (212099, 201079, '2011-06-28 10:07:00', 10.0000, 'CR2002', NULL, 'payment', NULL, 201799, 'deposit', 1);


SET search_path = payment, pg_catalog;

--
-- Data for Name: affiliate_reward; Type: TABLE DATA; Schema: payment; Owner: postgres
--

INSERT INTO affiliate_reward VALUES (201659, '2009-09-01', '2009-09-30');
INSERT INTO affiliate_reward VALUES (201679, '2009-09-01', '2009-09-30');


--
-- Data for Name: bank_wire; Type: TABLE DATA; Schema: payment; Owner: postgres
--

INSERT INTO bank_wire VALUES (200379, 'Sutrisno Suryoputro', 'RBSI 5880-58269864', '2009-11-18 00:00:00', '46510567', '', '', '', '', '', '', '', '', 'Bank Name  HSBC Bank; Acct No  007-059066-081; Acct Name  Sutrisno Suryoputro');


--
-- Data for Name: doughflow; Type: TABLE DATA; Schema: payment; Owner: postgres
--

INSERT INTO doughflow VALUES (12003, 'deposit', 1, 'DFHelpDesk', 'Manual', '', '');


--
-- Data for Name: free_gift; Type: TABLE DATA; Schema: payment; Owner: postgres
--

INSERT INTO free_gift VALUES (200159, NULL, 'Free gift (claimed from mobile 611234567)');
INSERT INTO free_gift VALUES (200219, NULL, 'Free gift (claimed from mobile 611234567)');
INSERT INTO free_gift VALUES (200439, NULL, 'Free gift (claimed from mobile 611231242)');
INSERT INTO free_gift VALUES (200499, NULL, 'Free gift (claimed from mobile 6712345678) (4900200063643402,) TIMESTAMP=18-Nov-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS ');
INSERT INTO free_gift VALUES (200519, NULL, 'Free gift (claimed from mobile 611234549) (4900200063643402,) TIMESTAMP=10-Sep-09 04h18GMT CCHH 0283E9A742FA8DE5547099BD2F88B404 V99042100 VISA 3DS ');
INSERT INTO free_gift VALUES (200699, NULL, 'Free gift (claimed from mobile 611234567)');
INSERT INTO free_gift VALUES (200759, NULL, 'Free gift (claimed from mobile 441234567890)');
INSERT INTO free_gift VALUES (200799, NULL, 'Free gift (claimed from mobile 611234549)');
INSERT INTO free_gift VALUES (200819, NULL, 'Free gift (claimed from mobile 611234549)');
INSERT INTO free_gift VALUES (200879, NULL, 'Free gift (claimed from mobile 611234549)');
INSERT INTO free_gift VALUES (200899, NULL, 'Free gift (claimed from mobile 611234549)');
INSERT INTO free_gift VALUES (200939, NULL, 'Free gift (claimed from mobile 611234549)');
INSERT INTO free_gift VALUES (200979, NULL, 'Free gift (claimed from mobile 611234549)');
INSERT INTO free_gift VALUES (201099, NULL, 'Free gift (claimed from mobile 611234549)');
INSERT INTO free_gift VALUES (201139, NULL, 'Free gift (claimed from mobile 611234549)');
INSERT INTO free_gift VALUES (201359, NULL, 'Free gift (claimed from mobile 611234549)');
INSERT INTO free_gift VALUES (201399, NULL, 'Free gift (claimed from mobile 611234549)');


--
-- Data for Name: legacy_payment; Type: TABLE DATA; Schema: payment; Owner: postgres
--

INSERT INTO legacy_payment VALUES (200019, 'compacted_statement');
INSERT INTO legacy_payment VALUES (200059, 'misc');
INSERT INTO legacy_payment VALUES (200069, 'misc');
INSERT INTO legacy_payment VALUES (200070, 'misc');
INSERT INTO legacy_payment VALUES (200079, 'neteller');
INSERT INTO legacy_payment VALUES (200559, 'egold');
INSERT INTO legacy_payment VALUES (200599, 'egold');
INSERT INTO legacy_payment VALUES (200619, 'egold');
INSERT INTO legacy_payment VALUES (200639, 'egold');
INSERT INTO legacy_payment VALUES (200719, 'virtual_credit');
INSERT INTO legacy_payment VALUES (200739, 'virtual_credit');
INSERT INTO legacy_payment VALUES (200779, 'egold');
INSERT INTO legacy_payment VALUES (201459, 'egold');
INSERT INTO legacy_payment VALUES (201519, 'ebullion');
INSERT INTO legacy_payment VALUES (201559, 'ebullion');
INSERT INTO legacy_payment VALUES (201579, 'ebullion');
INSERT INTO legacy_payment VALUES (201599, 'adjustment');


SET search_path = sequences, pg_catalog;

--
-- Name: account_serial; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('account_serial', 200039, false);


--
-- Name: bet_serial; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('bet_serial', 200039, false);


--
-- Name: global_serial; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('global_serial', 1159, true);


--
-- Name: loginid_sequence_bft; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_bft', 2000, false);


--
-- Name: loginid_sequence_cbet; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_cbet', 8000, false);


--
-- Name: loginid_sequence_cr; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_cr', 170000, false);


--
-- Name: loginid_sequence_em; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_em', 2000, false);


--
-- Name: loginid_sequence_fotc; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_fotc', 2000, false);


--
-- Name: loginid_sequence_ftb; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_ftb', 12000, false);


--
-- Name: loginid_sequence_mkt; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_mkt', 2000, false);


--
-- Name: loginid_sequence_mlt; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_mlt', 70000, false);


--
-- Name: loginid_sequence_mx; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_mx', 30000, false);


--
-- Name: loginid_sequence_mxr; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_mxr', 13000, false);


--
-- Name: loginid_sequence_nf; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_nf', 2000, false);


--
-- Name: loginid_sequence_otc; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_otc', 2000, false);


--
-- Name: loginid_sequence_rcp; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_rcp', 2000, false);


--
-- Name: loginid_sequence_test; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_test', 16000, false);


--
-- Name: loginid_sequence_uk; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_uk', 19000, false);


--
-- Name: loginid_sequence_vrt; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrt', 8000, false);


--
-- Name: loginid_sequence_vrtb; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtb', 2000, false);


--
-- Name: loginid_sequence_vrtc; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtc', 380000, false);


--
-- Name: loginid_sequence_vrte; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrte', 2000, false);


--
-- Name: loginid_sequence_vrtf; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtf', 7000, false);


--
-- Name: loginid_sequence_vrtm; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtm', 35000, false);


--
-- Name: loginid_sequence_vrtmkt; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtmkt', 3000, false);


--
-- Name: loginid_sequence_vrtn; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtn', 2000, false);


--
-- Name: loginid_sequence_vrto; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrto', 2000, false);


--
-- Name: loginid_sequence_vrtotc; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtotc', 6000, false);


--
-- Name: loginid_sequence_vrtp; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtp', 2000, false);


--
-- Name: loginid_sequence_vrtr; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtr', 2000, false);


--
-- Name: loginid_sequence_vrts; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrts', 20000, false);


--
-- Name: loginid_sequence_vrtu; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_vrtu', 30000, false);


--
-- Name: loginid_sequence_ws; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_sequence_ws', 20000, false);


--
-- Name: loginid_serial; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('loginid_serial', 219, false);


--
-- Name: payment_serial; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('payment_serial', 200039, false);

--
--

SELECT pg_catalog.setval('serials_configurations_id_seq', 58, true);


--
-- Name: transaction_serial; Type: SEQUENCE SET; Schema: sequences; Owner: postgres
--

SELECT pg_catalog.setval('transaction_serial', 200039, false);


--
-- PostgreSQL database dump complete
--

