#!/bin/bash

# Pindah ke direktori project
cd /home/niam/flow-monitor

echo "Mulai Update ASN: $(date)"

# 1. Jalankan script Python untuk download & konversi (hasilnya file asn_data.csv)
/usr/bin/python3 update_asn.py

# 2. Kosongkan tabel ClickHouse lama, lalu suntikkan data CSV yang baru
sudo docker exec -i flow-monitor-clickhouse-1 clickhouse-client --query="TRUNCATE TABLE netflow.asn_data"
cat asn_data.csv | sudo docker exec -i flow-monitor-clickhouse-1 clickhouse-client --query="INSERT INTO netflow.asn_data FORMAT CSV"

# 3. Beritahu ClickHouse untuk me-reload kamusnya di RAM
sudo docker exec -i flow-monitor-clickhouse-1 clickhouse-client --query="SYSTEM RELOAD DICTIONARY netflow.asn_dict"

echo "Selesai Update ASN: $(date)"
echo "----------------------------------------"


# 0 2 * * * /home/niam/flow-monitor/update_asn.sh >> /home/niam/flow-monitor/asn_update.log 2>&1