sudo apt update
sudo apt install docker.io docker-compose-v2 -y
sudo systemctl enable --now docker

# nano /etc/pve/lxc/CTID.conf
unprivileged: 0
lxc.apparmor.profile: unconfined

# 1. Hapus total aplikasi AppArmor yang membingungkan Docker di dalam LXC
sudo apt purge apparmor -y

# 2. Restart layanan Docker agar ia sadar AppArmor sudah tidak ada
sudo systemctl restart docker

# 3. Jalankan kembali arsitektur kita
docker compose up -d


sudo tcpdump -i any udp port 6343 -n

docker exec -it flow-monitor-clickhouse-1 clickhouse-client

-- =======================================================================
-- TAHAP 1: PERSIAPAN DATABASE & PEMBERSIHAN
-- =======================================================================
CREATE DATABASE IF NOT EXISTS netflow;

-- Bersihkan pipa dan tabel lama agar tidak bentrok saat dibuat ulang
DROP TABLE IF EXISTS netflow.flows_mv;
DROP TABLE IF EXISTS netflow.kafka_flows;
DROP TABLE IF EXISTS netflow.flows_hourly_mv;
DROP TABLE IF EXISTS netflow.flows_hourly;
DROP TABLE IF EXISTS netflow.flows;
DROP DICTIONARY IF EXISTS netflow.router_dict;
DROP TABLE IF EXISTS netflow.routers;
DROP DICTIONARY IF EXISTS netflow.asn_dict;
DROP TABLE IF EXISTS netflow.asn_data;

-- =======================================================================
-- TAHAP 2: KAMUS ROUTER & KALIBRASI SAMPLING RATE
-- =======================================================================
-- Tabel fisik penampung daftar router
CREATE TABLE netflow.routers (
    sampler_address String,
    name String,
    sampling UInt32
) ENGINE = MergeTree()
ORDER BY sampler_address;

-- Kamus (RAM) pembaca daftar router
CREATE DICTIONARY netflow.router_dict (
    sampler_address String,
    name String,
    sampling UInt32
) PRIMARY KEY sampler_address
SOURCE(CLICKHOUSE(DB 'netflow' TABLE 'routers'))
LIFETIME(MIN 300 MAX 360) LAYOUT(COMPLEX_KEY_HASHED());

-- =======================================================================
-- TAHAP 3: KAMUS BGP ASN (DATABASE GLOBAL)
-- =======================================================================
-- Tabel fisik penampung data IP to ASN
CREATE TABLE netflow.asn_data (
    ip_range String,
    asn UInt32,
    asn_name String
) ENGINE = MergeTree()
ORDER BY ip_range;

-- Kamus (RAM) berkinerja tinggi menggunakan algoritma ip_trie
CREATE DICTIONARY netflow.asn_dict (
    ip_range String,
    asn UInt32,
    asn_name String
) PRIMARY KEY ip_range
SOURCE(CLICKHOUSE(DB 'netflow' TABLE 'asn_data'))
LIFETIME(MIN 3600 MAX 7200) LAYOUT(ip_trie());

-- =======================================================================
-- TAHAP 4: TABEL UTAMA (PENYIMPANAN RAW DATA SFLOW 7 HARI)
-- =======================================================================
CREATE TABLE netflow.flows (
    Date Date,
    TimeReceived DateTime,
    sampler_address String,
    src_addr String,
    dst_addr String,
    src_port UInt32,
    dst_port UInt32,
    tcp_flags UInt32,
    bytes UInt64,
    packets UInt64,
    proto String
) ENGINE = MergeTree()
PARTITION BY Date
ORDER BY (TimeReceived, sampler_address)
TTL Date + INTERVAL 7 DAY;

-- =======================================================================
-- TAHAP 5: CORONG KAFKA (HOST NETWORK MODE)
-- =======================================================================
CREATE TABLE netflow.kafka_flows (
    sampler_address String,
    src_addr String,
    dst_addr String,
    src_port UInt32,
    dst_port UInt32,
    tcp_flags UInt32,
    proto String,
    bytes UInt64,
    packets UInt64
) ENGINE = Kafka
SETTINGS kafka_broker_list = '127.0.0.1:9092',
         kafka_topic_list = 'flows',
         kafka_group_name = 'clickhouse_reader',
         kafka_format = 'JSONEachRow';

-- =======================================================================
-- TAHAP 6: PIPA PENGHUBUNG (MENGALIKAN TRAFIK DENGAN SAMPLING RATE)
-- =======================================================================
CREATE MATERIALIZED VIEW netflow.flows_mv TO netflow.flows AS
SELECT
    toDate(now()) AS Date,
    now() AS TimeReceived,
    sampler_address,
    src_addr,
    dst_addr,
    src_port,
    dst_port,
    tcp_flags,
    -- Rumus ajaib: Mengembalikan volume trafik ke ukuran aslinya
    bytes * dictGetOrDefault('netflow.router_dict', 'sampling', tuple(sampler_address), toUInt32(1)) AS bytes,
    packets * dictGetOrDefault('netflow.router_dict', 'sampling', tuple(sampler_address), toUInt32(1)) AS packets,
    proto
FROM netflow.kafka_flows;

-- =======================================================================
-- TAHAP 7: TABEL HISTORIS (PENYIMPANAN RINGAN 1 TAHUN)
-- =======================================================================
CREATE TABLE netflow.flows_hourly (
    Date Date,
    Hour DateTime,
    sampler_address String,
    src_asn_name String,
    dst_asn_name String,
    proto String,
    total_bytes UInt64,
    total_packets UInt64
) ENGINE = SummingMergeTree()
ORDER BY (Date, Hour, sampler_address, src_asn_name, dst_asn_name, proto)
TTL Date + INTERVAL 1 YEAR;

-- =======================================================================
-- TAHAP 8: PIPA HISTORIS (RESOLUSI ASN OTOMATIS)
-- =======================================================================
CREATE MATERIALIZED VIEW netflow.flows_hourly_mv TO netflow.flows_hourly AS
SELECT
    toDate(TimeReceived) AS Date,
    toStartOfHour(TimeReceived) AS Hour,
    sampler_address,
    dictGetOrDefault('netflow.asn_dict', 'asn_name', tuple(toIPv4OrDefault(src_addr)), 'Unknown ASN') AS src_asn_name,
    dictGetOrDefault('netflow.asn_dict', 'asn_name', tuple(toIPv4OrDefault(dst_addr)), 'Unknown ASN') AS dst_asn_name,
    proto,
    sum(bytes) AS total_bytes,
    sum(packets) AS total_packets
FROM netflow.flows
GROUP BY Date, Hour, sampler_address, src_asn_name, dst_asn_name, proto;

-- Masukkan IP Router yang terdeteksi di tcpdump tadi
INSERT INTO netflow.routers VALUES ('10.225.98.2', 'Router-NOC-Utama', 1024);

-- Paksa ClickHouse membaca ulang memori kamus
SYSTEM RELOAD DICTIONARY netflow.router_dict;