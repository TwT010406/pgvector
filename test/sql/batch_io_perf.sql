-- ============================================
-- 批量 IO 性能对比测试脚本 (修正版)
-- 验证 ivfflat.batch_enable_sort 参数的效果
-- 重点：大数据量以突破内存限制，模拟真实磁盘 I/O
-- ============================================

CREATE EXTENSION IF NOT EXISTS vector;

-- 1. 创建测试环境
\echo '=== Step 1: 准备测试数据 (Scale Up) ==='
DROP TABLE IF EXISTS test_io_perf CASCADE;
CREATE TABLE test_io_perf (
    id SERIAL PRIMARY KEY,
    embedding vector(128),
    payload text  -- 增加 payload 大小以确保数据不全在内存中
);

-- 插入 50万 条数据 (约 500MB+)
-- payload 大小设为 500 字节，总表大小约为 500,000 * 1KB ≈ 500MB
-- 加上索引，如果 shared_buffers 较小（默认128MB），可以触发 I/O
INSERT INTO test_io_perf (id, embedding, payload) 
SELECT 
    i,
    (SELECT array_agg(sin(i + j)) FROM generate_series(1, 128) j)::vector(128),
    repeat('padding_data_', 40) || i  
FROM generate_series(1, 500000) i;

CREATE INDEX test_io_perf_idx ON test_io_perf 
USING ivfflat (embedding vector_l2_ops) 
WITH (lists = 500);

ANALYZE test_io_perf;

-- 2. 准备查询向量 (模拟一批随机查询)
\set query_batch '(SELECT array_agg(embedding) FROM (SELECT (SELECT array_agg(sin(k + j)) FROM generate_series(1, 128) j)::vector(128) as embedding FROM generate_series(1, 100) k) t)'

\echo ''
\echo '-------------------------------------------------------------'
\echo '注意：为了获得准确的 I/O 性能对比，建议在 Step 2 和 Step 3 之间'
\echo '重启 PostgreSQL 并清除操作系统缓存 (echo 3 > /proc/sys/vm/drop_caches)'
\echo '-------------------------------------------------------------'
\echo ''

\echo '=== Step 2: 执行基准测试 (Sort Enabled - 顺序 I/O) ==='
SET ivfflat.batch_enable_sort = on;
SHOW ivfflat.batch_enable_sort;

\timing on
-- 预热 (加载索引元数据)
SELECT count(*) FROM batch_vector_search(
    (SELECT oid FROM pg_class WHERE relname = 'test_io_perf_idx'),
    vector_batch_from_array(:query_batch),
    10
);

-- 正式测试 (Sort ON)
-- 预期：I/O Wait 较低，总耗时较短
SELECT count(*) FROM batch_vector_search(
    (SELECT oid FROM pg_class WHERE relname = 'test_io_perf_idx'),
    vector_batch_from_array(:query_batch),
    10
);
\timing off

\echo ''
\echo '=== (此处建议手动重启服务并清缓存) ==='
\echo ''

\echo '=== Step 3: 执行对比测试 (Sort Disabled - 随机 I/O) ==='
SET ivfflat.batch_enable_sort = off;
SHOW ivfflat.batch_enable_sort;

\timing on
-- 预热
SELECT count(*) FROM batch_vector_search(
    (SELECT oid FROM pg_class WHERE relname = 'test_io_perf_idx'),
    vector_batch_from_array(:query_batch),
    10
);

-- 正式测试 (Sort OFF)
-- 预期：在冷数据场景下，耗时应显著增加
SELECT count(*) FROM batch_vector_search(
    (SELECT oid FROM pg_class WHERE relname = 'test_io_perf_idx'),
    vector_batch_from_array(:query_batch),
    10
);
\timing off

\echo '=== 测试结束 ==='
