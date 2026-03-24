# update_asn.py
import urllib.request
import gzip
import ipaddress
import csv

url = 'https://iptoasn.com/data/ip2asn-v4.tsv.gz'
print("1. Mengunduh Database IP2ASN Global (Menyamar sebagai Chrome)...")

# Menambahkan header User-Agent agar tidak diblokir server (Error 403)
req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'})

with urllib.request.urlopen(req) as response, open('ip2asn.tsv.gz', 'wb') as out_file:
    out_file.write(response.read())

print("2. Mengkonversi IP Range menjadi CIDR (Tunggu sekitar 1-2 menit)...")
with gzip.open('ip2asn.tsv.gz', 'rt', encoding='utf-8') as f_in, open('asn_data.csv', 'w', newline='', encoding='utf-8') as f_out:
    writer = csv.writer(f_out)
    for line in f_in:
        parts = line.strip().split('\t')
        if len(parts) >= 5:
            start_ip, end_ip, asn, country, name = parts[0], parts[1], parts[2], parts[3], parts[4]
            if asn == '0': continue
            try:
                start = ipaddress.IPv4Address(start_ip)
                end = ipaddress.IPv4Address(end_ip)
                cidrs = ipaddress.summarize_address_range(start, end)
                for cidr in cidrs:
                    writer.writerow([str(cidr), asn, name])
            except:
                pass
print("3. Selesai! Data berhasil disimpan ke asn_data.csv")

