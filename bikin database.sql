docker exec -it flow-monitor-clickhouse-1 clickhouse-client

CREATE DATABASE IF NOT EXISTS netflow;
CREATE USER IF NOT EXISTS grafana IDENTIFIED WITH no_password;
GRANT SELECT ON netflow.* TO grafana;
GRANT dictGet ON netflow.* TO grafana;

-- =========================================================
-- 1) BUAT DATABASE
-- =========================================================
CREATE DATABASE IF NOT EXISTS netflow;


-- =========================================================
-- 2) TABEL SUMBER ASN
-- Dipakai oleh dictionary: netflow.asn_dict
-- =========================================================
CREATE TABLE netflow.asn_data
(
    `prefix` String,
    `asn` UInt32,
    `asn_name` String
)
ENGINE = MergeTree
ORDER BY prefix
SETTINGS index_granularity = 8192;


-- =========================================================
-- 3) TABEL SUMBER ROUTER
-- Dipakai oleh dictionary: netflow.router_dict
-- =========================================================
CREATE TABLE netflow.routers
(
    `ip` String,
    `name` String,
    `sampling` UInt32
)
ENGINE = MergeTree
ORDER BY ip
SETTINGS index_granularity = 8192;


-- =========================================================
-- 4) TABEL FLOW UTAMA
-- Target dari materialized view: netflow.flows_mv
-- =========================================================
CREATE TABLE netflow.flows
(
    `Date` Date,
    `TimeReceived` DateTime,
    `sampler_address` String,
    `src_addr` String,
    `dst_addr` String,
    `src_port` UInt32,
    `dst_port` UInt32,
    `tcp_flags` UInt32,
    `bytes` UInt64,
    `packets` UInt64,
    `proto` String
)
ENGINE = MergeTree
PARTITION BY Date
ORDER BY (TimeReceived, src_addr, dst_addr)
TTL Date + toIntervalDay(7)
SETTINGS index_granularity = 8192;


-- =========================================================
-- 5) TABEL AGREGASI HOURLY
-- Target dari materialized view: netflow.flows_hourly_mv
-- =========================================================
CREATE TABLE netflow.flows_hourly
(
    `Date` Date,
    `Hour` DateTime,
    `sampler_address` String,
    `src_asn_name` String,
    `dst_asn_name` String,
    `proto` String,
    `total_bytes` UInt64,
    `total_packets` UInt64
)
ENGINE = SummingMergeTree
ORDER BY (Date, Hour, sampler_address, src_asn_name, dst_asn_name, proto)
TTL Date + toIntervalYear(1)
SETTINGS index_granularity = 8192;


-- =========================================================
-- 6) DICTIONARY ASN
-- Sumber data: netflow.asn_data
-- Harus dibuat setelah tabel asn_data ada
-- =========================================================
CREATE DICTIONARY netflow.asn_dict
(
    `prefix` String,
    `asn` UInt32,
    `asn_name` String
)
PRIMARY KEY prefix
SOURCE(CLICKHOUSE(
    HOST 'localhost'
    PORT 9000
    USER 'default'
    TABLE 'asn_data'
    DB 'netflow'
))
LIFETIME(MIN 3600 MAX 86400)
LAYOUT(IP_TRIE);


-- =========================================================
-- 7) DICTIONARY ROUTER
-- Sumber data: netflow.routers
-- Harus dibuat setelah tabel routers ada
-- =========================================================
CREATE DICTIONARY netflow.router_dict
(
    `ip` String,
    `name` String,
    `sampling` UInt32
)
PRIMARY KEY ip
SOURCE(CLICKHOUSE(
    HOST 'localhost'
    PORT 9000
    USER 'default'
    TABLE 'routers'
    DB 'netflow'
))
LIFETIME(MIN 60 MAX 300)
LAYOUT(COMPLEX_KEY_HASHED());


-- =========================================================
-- 8) TABEL SOURCE DARI KAFKA
-- Data masuk dari Kafka topic: flows
-- =========================================================
CREATE TABLE netflow.kafka_flows
(
    `sampler_address` String,
    `src_addr` String,
    `dst_addr` String,
    `src_port` UInt32,
    `dst_port` UInt32,
    `tcp_flags` UInt32,
    `proto` String,
    `bytes` UInt64,
    `packets` UInt64
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka:29092',
    kafka_topic_list = 'flows',
    kafka_group_name = 'clickhouse_reader',
    kafka_format = 'JSONEachRow';


-- =========================================================
-- 9) MATERIALIZED VIEW:
-- Kafka -> flows
-- Butuh:
--   - netflow.kafka_flows
--   - netflow.flows
--   - netflow.router_dict
-- =========================================================
CREATE MATERIALIZED VIEW netflow.flows_mv
TO netflow.flows
(
    `Date` Date,
    `TimeReceived` DateTime,
    `sampler_address` String,
    `src_addr` String,
    `dst_addr` String,
    `src_port` UInt32,
    `dst_port` UInt32,
    `tcp_flags` UInt32,
    `bytes` UInt64,
    `packets` UInt64,
    `proto` String
)
AS
SELECT
    toDate(now()) AS Date,
    now() AS TimeReceived,
    sampler_address,
    src_addr,
    dst_addr,
    src_port,
    dst_port,
    tcp_flags,
    bytes * dictGetOrDefault('netflow.router_dict', 'sampling', tuple(sampler_address), toUInt32(1)) AS bytes,
    packets * dictGetOrDefault('netflow.router_dict', 'sampling', tuple(sampler_address), toUInt32(1)) AS packets,
    proto
FROM netflow.kafka_flows;


-- =========================================================
-- 10) MATERIALIZED VIEW:
-- flows -> flows_hourly
-- Butuh:
--   - netflow.flows
--   - netflow.flows_hourly
--   - netflow.asn_dict
-- =========================================================
CREATE MATERIALIZED VIEW netflow.flows_hourly_mv
TO netflow.flows_hourly
(
    `Date` Date,
    `Hour` DateTime,
    `sampler_address` String,
    `src_asn_name` String,
    `dst_asn_name` String,
    `proto` String,
    `total_bytes` UInt64,
    `total_packets` UInt64
)
AS
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
GROUP BY
    Date,
    Hour,
    sampler_address,
    src_asn_name,
    dst_asn_name,
    proto;


docker compose logs --tail=20 goflow2
