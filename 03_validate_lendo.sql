-- Run while connected to the Lendo database after 01_lendo_schema.sql.

-- 1) All base tables (expected: 25)
SELECT COUNT(*) AS base_table_count
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE';

SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;

-- 2) Foreign-key relationships (expected: 46)
SELECT COUNT(*) AS foreign_key_count
FROM information_schema.table_constraints
WHERE constraint_schema = 'public' AND constraint_type = 'FOREIGN KEY';

-- 3) Views
SELECT table_name AS view_name
FROM information_schema.views
WHERE table_schema = 'public'
ORDER BY table_name;

-- 4) Triggers installed on application tables
SELECT event_object_table AS table_name, trigger_name
FROM information_schema.triggers
WHERE trigger_schema = 'public'
ORDER BY event_object_table, trigger_name;

-- 5) Initial item categories
SELECT category_id, name, slug
FROM categories
ORDER BY name;
