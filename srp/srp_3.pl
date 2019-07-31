use strict;
use warnings;

use BOM::Database::ClientDB;

# Update address_state code change when we update Locale::SubCountry from v1.65 => v2.05

# hash of old code => new code
my %full_change_list;
%full_change_list = (
    cn =>{
      71 => 'TW',
      46 => 'HI',
      15 => 'NM',
      34 => 'AH',
      50 => 'CQ',
      42 => 'HB',
      23 => 'HL',
      11 => 'BJ',
      35 => 'FJ',
      13 => 'HE',
      51 => 'SC',
      52 => 'GZ',
      45 => 'GX',
      62 => 'GS',
      32 => 'JS',
      36 => 'JX',
      61 => 'SN',
      54 => 'XZ',
      41 => 'HA',
      65 => 'XJ',
      31 => 'SH',
      64 => 'NX',
      22 => 'JL',
      33 => 'ZJ',
      91 => 'HK',
      63 => 'QH',
      21 => 'LN',
      44 => 'GD',
      53 => 'YN',
      37 => 'SD',
      12 => 'TJ',
      43 => 'HN',
    },

    gb =>{
      ARM => 'ABC',
      CHS => 'CHE',
      ARD => 'AND',
      DOW => 'NMD',
      CSR => 'LBC',
      STB => 'DRS',
      CGV => 'ABC',
      FER => 'FMO',
      ANT => 'ANN',
      NYM => 'NMD',
      NDN => 'AND',
      DRY => 'DRS',
      OMH => 'FMO',
      NTA => 'ANN',
      LSB => 'LBC',
      BNB => 'ABC',
    },

    mh =>{
      WTH => 'WTN',
    },

    md =>{
      TI => 'BD',
      CH => 'CU',
    },

    ss =>{
      EE => 'EE8',
      EC => 'CE',
    },

    li =>{
      4 => '04',
      5 => '05',
      9 => '09',
      8 => '08',
      3 => '03',
      2 => '02',
      1 => '01',
      7 => '07',
    },

    ml => {
      BKO => 'BK0',
    },

    sc => {
      1 => '01',
      2 => '02',
      3 => '03',
      4 => '04',
      5 => '05',
      6 => '06',
      7 => '07',
      8 => '08',
      9 => '09',
    },

    cz => {
      OL => '71',
      JC => '31',
      MO => '80',
      PA => '53',
      PR => '10',
      ST => '20',
      LI => '51',
      VY => '63',
      ZL => '72',
      PL => '32',
      JM => '64',
      KR => '52',
      KA => '41',
      US => '42',
    },

    me => {
      AN => '09',
      UL => '20',
      KT => '10',
      ZA => '21',
      NK => '12',
      DA => '07',
      MK => '11',
      RO => '17',
      BU => '05',
      BA => '02',
      PV => '13',
      HN => '08',
      PG => '16',
      BP => '04',
      CE => '06',
      BE => '03',
      PU => '15',
      TI => '19',
      PL => '14',
      SA => '18',
      KL => '09',
    },

    bb =>{
      1 => '01',
      2 => '02',
      3 => '03',
      4 => '04',
      5 => '05',
      6 => '06',
      7 => '07',
      8 => '08',
      9 => '09',
    },

    pw =>{
      4 => '004',
      10 => '010',
      2 => '002',
      50 => '050',
    },

    vn =>{
      65 => 'SG',
      64 => 'HN',
      48 => 'CT',
      62 => 'HP',
      60 => 'DN',
    },

    vc =>{
      6 => '06',
      3 => '03',
      2 => '02',
      5 => '05',
      4 => '04',
      1 => '01',
    },

    sg =>{
      1 => '01',
      2 => '02',
      3 => '03',
      4 => '04',
      5 => '05',
    },

    ye =>{
      HU => 'MU',
    },

    ly =>{
      SH => 'WS',
    },

    sm =>{
      1 => '01',
      2 => '02',
      3 => '03',
      4 => '04',
      5 => '05',
      6 => '06',
      7 => '07',
      8 => '08',
      9 => '09',
    },

    mk =>{
      1 => '01',
      2 => '02',
      3 => '03',
      4 => '04',
      5 => '05',
      6 => '06',
      7 => '07',
      8 => '08',
      9 => '09',
    },

    bs =>{
      SR => 'SS',
      AC => 'AK',
    },

    lv =>{
      VM => 'VMR',
      RE => '077',
      OG => '067',
      AL => '007',
      TU => '099',
      BU => '016',
      KU => '050',
      MA => '059',
      BL => '015',
      LU => '058',
      LM => '054',
      VE => '106',
      JL => '041',
      CE => '022',
      TA => '097',
      JK => '042',
      DA => '025',
      KR => '047',
      PR => '073',
      VK => '101',
      AI => '002',
      GU => '033',
      SA => '088',
      DO => '026',
    },

    bh =>{
      '03' => '13',
      '02' => '15',
    },

    ph =>{
      'MM' => '00',
    },

    in =>{
      UL => 'UT',
    },

    gd =>{
      MA => '05',
      GE => '03',
      PA => '06',
      AN => '01',
      DA => '02',
      JO => '04',
    },

    ag =>{
      3 => '03',
      4 => '04',
      5 => '05',
      6 => '06',
      7 => '07',
      8 => '08',
    },

    nr =>{
      1 => '01',
      2 => '02',
      3 => '03',
      4 => '04',
      5 => '05',
      6 => '06',
      7 => '07',
      8 => '08',
      9 => '09',
    },

    mu =>{
      RR => 'RP',
    },

    az =>{
      SS => 'SUS',
    },

    iq =>{
      SU => 'SW',
    },

    mx =>{
      DIF => 'CMX',
    },

    rw =>{
      L => '01',
    },

    kn =>{
      1 => '01',
      2 => '02',
      3 => '03',
      4 => '04',
      5 => '05',
      6 => '06',
      7 => '07',
      8 => '08',
      9 => '09',
    },

    dm =>{
      1 => '01',
      2 => '02',
      3 => '03',
      4 => '04',
      5 => '05',
      6 => '06',
      7 => '07',
      8 => '08',
      9 => '09',
    },

    la =>{
      XN => 'XS',
    },

    ma =>{
      BAH => 'CHT',
      MEL => 'INE',
      MAR => 'MMD',
      RBA => '07',
    },

    rs =>{
      KP => '29',
      PZ => '27',
      BR => '11',
      RS => '18',
      ZL => '16',
      PE => '26',
      RN => '19',
      JC => '23',
      JA => '23',
      SD => '02',
      PI => '22',
      BO => '14',
      SU => '12',
      SN => '03',
      Zj => '15',
      PC => '24',
      SM => '07',
      ZC => '05',
      PC => '24',
      SM => '07',
      ZC => '05',
      MA => '08',
      SC => '01',
      MR => '17',
      PM => '13',
      KO => 'KM',
      NS => '20',
      KB => '09',
      BG => '00',
      JN => '04',
      TO => '21',
    },

    it => {
      PS => 'PU',
      FO => 'FC',
    },

    kp =>{
      KAN => '07',
      NAJ => '13',
      HAN => '08',
      PYB => '03',
      HWB => '06',
      HWN => '05',
      PYO => '01',
      YAN => '10',
      CHA => '04',
      HAB => '09',
      PYN => '02',
    },

);

my @broker = qw(CR MLT MX MF);

for my $current_broker (@broker){
    
    my $dbic = BOM::Database::ClientDB->new({
        broker_code => $current_broker,
    })->db->dbic;
    
    for my $country (keys %full_change_list){
        for my $subcountry_code (keys %{$full_change_list{$country}}){
            my $sth = $dbic->run(fixup => sub {
                my $sth = $_->prepare(qq{
                  SELECT audit.set_staff('SRP https://trello.com/c/MCLVmIqJ', '127.0.0.1');
                  UPDATE betonmarkets.client SET address_state = ? WHERE residence = ? AND address_state =?});
                $sth->execute($full_change_list{$country}{$subcountry_code}, $country, $subcountry_code);
                $sth;
            });
        }
        
    }
    
}
