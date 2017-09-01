SELECT * FROM bdr_regress_variables()
\gset

\set VERBOSITY terse

\c :node1_dsn
CREATE EXTENSION bdr CASCADE;

SELECT E'\'' || current_database() || E'\'' AS node1_db
\gset

\c :node2_dsn
CREATE EXTENSION bdr CASCADE;

SELECT E'\'' || current_database() || E'\'' AS node2_db
\gset

\c :node1_dsn

-- Only used in tests
CREATE FUNCTION bdr_submit_comment(message text)
RETURNS text LANGUAGE c STRICT AS 'bdr','bdr_submit_comment';

SELECT * FROM bdr.node_group_member_info(NULL);

SELECT 1
FROM bdr.create_node(node_name := 'node1', local_dsn := :'node1_dsn' || ' user=super');

SELECT * FROM bdr.node_group_member_info(NULL);

SELECT 1
FROM bdr.create_node_group('bdrgroup');

SELECT * FROM bdr.node_group_member_info(NULL);
SELECT * FROM bdr.node_group_member_info((SELECT node_group_id FROM bdr.node_group));
SELECT * FROM bdr.node;
SELECT * FROM bdr.node_group;

SELECT * FROM bdr.node_group_replication_sets;

-- We must create a slot before creating the subscription to work
-- around the deadlock in 2ndQuadrant/pglogical_internal#152
-- TODO: BDR should do this automatically
SELECT slot_name FROM pg_create_logical_replication_slot(pglogical.pglogical_gen_slot_name(:node2_db, 'node1', 'bdrgroup'), 'pglogical');

\c :node2_dsn

SELECT * FROM bdr.node_group_member_info(NULL);

SELECT 1
FROM bdr.create_node(node_name := 'node2', local_dsn := :'node2_dsn' || ' user=super');

SELECT 1
FROM bdr.join_node_group(:'node1_dsn', 'nosuch-nodegroup');

SELECT * FROM bdr.node_group_member_info((SELECT node_group_id FROM bdr.node_group));

SELECT 1
FROM bdr.join_node_group(:'node1_dsn', 'bdrgroup');

SELECT * FROM bdr.node_group_member_info((SELECT node_group_id FROM bdr.node_group));
SELECT * FROM bdr.node_group_replication_sets;

-- Subscribe to the first node
-- See GH#152 for why we don't create the slot
-- TODO: BDR should do this for us

SELECT * FROM pglogical.node;
SELECT * FROM pglogical.node_interface;

SELECT 1 FROM pglogical.create_subscription(
    subscription_name := 'bdrgroup',
    provider_dsn := ( :'node1_dsn' || ' user=super' ),
    synchronize_structure := true,
    forward_origins := '{}',
    replication_sets := ARRAY['bdrgroup','ddl_sql'],
	create_slot := false);
-- and set the subscription as 'isinternal' so BDR thinks BDR owns it.
UPDATE pglogical.subscription SET sub_isinternal = true;

-- BDR would usually auto-create this but it doesn't know how
-- yet, so do it manually
SELECT 1 FROM pglogical.create_replication_set('dummy_nodegroup');

-- Wait for the initial copy to finish
--
-- If we don't do this, we'll usually kill the apply worker during init
-- and it won't retry since it doesn't know if the restore was partial
-- last time around
DO LANGUAGE plpgsql $$
BEGIN
  WHILE NOT EXISTS (SELECT 1 FROM pglogical.show_subscription_status() WHERE status = 'replicating')
  LOOP
    PERFORM pg_sleep(0.5);
  END LOOP;
END;
$$;

SELECT subscription_name, status, provider_node, slot_name, replication_sets
FROM pglogical.show_subscription_status();

-- See above...
-- TODO: BDR should do this automatically
SELECT slot_name FROM pg_create_logical_replication_slot(pglogical.pglogical_gen_slot_name(:node1_db, 'node2', 'bdrgroup'), 'pglogical');

\c :node1_dsn

-- Subscribe to the second node and make the subscription 'internal'
-- but this time don't sync structure.
--
-- See GH#152 for why we don't create the slot
SELECT 1 FROM pglogical.create_subscription(
    subscription_name := 'bdrgroup',
    provider_dsn := ( :'node2_dsn' || ' user=super' ),
    synchronize_structure := false,
    forward_origins := '{}',
    replication_sets := ARRAY['bdrgroup','ddl_sql'],
    create_slot := false);

UPDATE pglogical.subscription SET sub_isinternal = true;

DO LANGUAGE plpgsql $$
BEGIN
  WHILE NOT EXISTS (SELECT 1 FROM pglogical.show_subscription_status() WHERE status = 'replicating')
  LOOP
    PERFORM pg_sleep(0.5);
  END LOOP;
END;
$$;

SELECT subscription_name, status, provider_node, slot_name, replication_sets
FROM pglogical.show_subscription_status();

-- Now, since BDR doesn't know we changed any catalogs etc,
-- restart pglogical to make the plugin re-read its config

SET client_min_messages = error;

CREATE TEMPORARY TABLE throwaway AS
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE pid <> pg_backend_pid();

DROP TABLE throwaway;

SET client_min_messages = notice;

-- Wait for it to start up

-- We already created the slots so all we have to do here is wait for
-- the slots to be in sync once we do some WAL-logged work on the
-- upstreams.

CREATE TABLE throwaway AS SELECT 1;

\c :node2_dsn

CREATE TABLE throwaway AS SELECT 1;

\c :node1_dsn

SELECT pglogical.wait_slot_confirm_lsn(NULL, NULL);

SELECT application_name, sync_state
FROM pg_stat_replication
ORDER BY application_name;

SELECT slot_name, plugin, slot_type, database, temporary, active
FROM pg_replication_slots ORDER BY slot_name;

SELECT
    backend_type,
    regexp_replace(application_name, '[[:digit:]]', 'n', 'g') AS appname
FROM pg_stat_activity
WHERE application_name LIKE 'pglogical%';
