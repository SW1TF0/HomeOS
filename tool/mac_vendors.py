"""Makes assets/mac_vendors.txt.gz, the list of who made a network card, from the IEEE registry.

The first half of a MAC address says which company made the device. The IEEE publishes who has which block; the
oui-data package (https://github.com/silverwind/oui-data, BSD-2-Clause) has the same list as JSON:

    npm pack oui-data && tar -xzf oui-data-*.tgz
    python3 tool/mac_vendors.py package/index.json assets/mac_vendors.txt.gz

Each line of the result is a prefix of 6, 7 or 9 hex digits (the large, medium and small blocks), a tab and a short
company name: "Apple" rather than "Apple, Inc.", "TP-Link" rather than "TP-LINK TECHNOLOGIES CO.,LTD.".
"""
import gzip
import json
import re
import sys

# Well-known makers, by a piece of the registered name, so devices read the way their boxes do.
BRANDS = [
    (r'^apple\b', 'Apple'),
    (r'honor device', 'Honor'),
    (r'huawei', 'Huawei'),
    (r'samsung', 'Samsung'),
    (r'xiaomi', 'Xiaomi'),
    (r'\boppo\b', 'OPPO'),
    (r'^vivo mobile', 'vivo'),
    (r'oneplus', 'OnePlus'),
    (r'realme', 'realme'),
    (r'motorola mobility', 'Motorola'),
    (r'^zte\b', 'ZTE'),
    (r'tp-link|tp link', 'TP-Link'),
    (r'^eero\b', 'eero'),
    (r'amazon technologies', 'Amazon'),
    (r'nest labs', 'Google Nest'),
    (r'^google', 'Google'),
    (r'^microsoft', 'Microsoft'),
    (r'^intel corporate|^intel corporation', 'Intel'),
    (r'espressif', 'Espressif'),
    (r'tuya', 'Tuya'),
    (r'hon hai precision', 'Foxconn'),
    (r'asustek', 'ASUS'),
    (r'hewlett packard enterprise', 'HPE'),
    (r'^hewlett packard|^hp inc', 'HP'),
    (r'^dell\b', 'Dell'),
    (r'lenovo', 'Lenovo'),
    (r'^lg electronics|^lg innotek', 'LG'),
    (r'sony interactive', 'PlayStation'),
    (r'^sony\b', 'Sony'),
    (r'nintendo', 'Nintendo'),
    (r'^sonos', 'Sonos'),
    (r'^roku', 'Roku'),
    (r'irobot', 'iRobot'),
    (r'ecovacs', 'Ecovacs'),
    (r'roborock', 'Roborock'),
    (r'dreame', 'Dreame'),
    (r'hikvision', 'Hikvision'),
    (r'dahua', 'Dahua / Imou'),
    (r'ezviz', 'EZVIZ'),
    (r'reolink', 'Reolink'),
    (r'ubiquiti', 'Ubiquiti'),
    (r'routerboard|mikrotik', 'MikroTik'),
    (r'netgear', 'NETGEAR'),
    (r'd-link', 'D-Link'),
    (r'zyxel', 'Zyxel'),
    (r'avm audiovisuelles', 'AVM FRITZ!'),
    (r'^tenda\b|shenzhen tenda', 'Tenda'),
    (r'linksys', 'Linksys'),
    (r'^belkin', 'Belkin'),
    (r'synology', 'Synology'),
    (r'^qnap', 'QNAP'),
    (r'raspberry pi', 'Raspberry Pi'),
    (r'^signify|philips lighting', 'Philips Hue'),
    (r'allterco|shelly', 'Shelly'),
    (r'yeelink|yeelight', 'Yeelight'),
    (r'seiko epson', 'Epson'),
    (r'^canon\b', 'Canon'),
    (r'brother industries', 'Brother'),
    (r'^xerox', 'Xerox'),
    (r'texas instruments', 'Texas Instruments'),
    (r'silicon laboratories', 'Silicon Labs'),
    (r'murata', 'Murata'),
    (r'azurewave', 'AzureWave'),
    (r'liteon|lite-on', 'Lite-On'),
    (r'universal global scientific', 'USI'),
    (r'realtek', 'Realtek'),
    (r'mediatek', 'MediaTek'),
    (r'qualcomm', 'Qualcomm'),
    (r'^broadcom', 'Broadcom'),
    (r'^tcl\b', 'TCL'),
    (r'hisense', 'Hisense'),
    (r'panasonic', 'Panasonic'),
    (r'^sharp\b', 'Sharp'),
    (r'tp vision', 'Philips TV'),
    (r'^vizio', 'Vizio'),
    (r'bsh hausger', 'Bosch Siemens'),
    (r'^miele', 'Miele'),
    (r'electrolux', 'Electrolux'),
    (r'^haier|qingdao haier', 'Haier'),
    (r'gree electric', 'Gree'),
    (r'midea', 'Midea'),
    (r'daikin', 'Daikin'),
    (r'^ring\b', 'Ring'),
    (r'^arlo', 'Arlo'),
    (r'wyze', 'Wyze'),
    (r'nvidia', 'NVIDIA'),
    (r'^cisco', 'Cisco'),
    (r'^nokia', 'Nokia'),
    (r'garmin', 'Garmin'),
    (r'fitbit', 'Fitbit'),
    (r'^bose\b', 'Bose'),
    (r'harman', 'Harman'),
    (r'^withings', 'Withings'),
    (r'^netatmo', 'Netatmo'),
    (r'^ikea', 'IKEA'),
    (r'^sagemcom', 'Sagemcom'),
    (r'^arcadyan', 'Arcadyan'),
    (r'^technicolor', 'Technicolor'),
]
BRANDS = [(re.compile(p), name) for p, name in BRANDS]

# Words that only say what kind of company it is.
_LEGAL = (r'co|corp|corporation|corporate|company|inc|incorporated|ltd|limited|llc|l\.l\.c|gmbh|mbh|ag|kg|sa|sas|s\.a'
          r'|s\.a\.s|s\.p\.a|spa|srl|s\.r\.l|bv|b\.v|nv|n\.v|oy|ab|as|asa|a/s|kk|plc|pte|pty|sdn bhd|bhd|lp|ooo|oao'
          r'|zao|jsc|ojsc|cjsc|s\.l|sl|sro|s\.r\.o|ltda|cv|de cv|sa de cv|pvt|private|holdings?|group|of|and|the')
_TAIL = re.compile(r'[\s,.\-&()]+$|(?:[\s,.(]+|^)(?:' + _LEGAL + r')\.?\)?$', re.I)
_CITIES = re.compile(r'^(shenzhen|beijing|guangdong|guangzhou|hangzhou|zhejiang|shanghai|xiamen|qingdao|dongguan|suzhou'
                     r'|chongqing|sichuan|jiangsu|fujian|wuhan|nanjing|ningbo|tianjin|foshan|zhuhai|huizhou|chengdu'
                     r'|hefei|jiangxi|shandong|hunan|hubei|anhui|zhongshan)\s+', re.I)


def short_name(registered):
    raw = registered.split('\n')[0].strip()
    low = raw.lower()
    if not raw or low == 'private' or low.startswith('ieee registration authority'):
        return None
    for pattern, name in BRANDS:
        if pattern.search(low):
            return name
    name = raw
    if name.count('(') > name.count(')'):
        name = name[:name.rindex('(')]
    while True:
        cut = _TAIL.sub('', name).strip()
        if cut == name or not cut:
            break
        name = cut
    city = _CITIES.sub('', name)
    if city.strip():
        name = city
    if not re.search('[a-z]', name):
        name = ' '.join(w if len(w) <= 3 else w.capitalize() for w in name.split())
    name = re.sub(r'\s+', ' ', name).strip()
    return name[:40].rstrip(' ,.-&(') or None


def main(src, dst):
    data = json.load(open(src, encoding='utf-8'))
    lines = []
    for prefix in sorted(data):
        name = short_name(data[prefix])
        if name:
            lines.append(f'{prefix.upper()}\t{name}\n')
    with open(dst, 'wb') as f:
        # No name or time in the header, so the same list always gives the same file.
        with gzip.GzipFile(filename='', fileobj=f, mode='wb', mtime=0, compresslevel=9) as z:
            z.write(''.join(lines).encode('utf-8'))
    print(f'{len(lines)} prefixes')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
