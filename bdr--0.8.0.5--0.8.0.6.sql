-- Data structures for BDR's dynamic configuration management

SET LOCAL search_path = bdr;
SET bdr.permit_unsafe_ddl_commands = true;
SET bdr.skip_ddl_replication = true;

CREATE TABLE bdr_connections (
    conn_sysid oid not null, -- Really a uint64 but we have no type for that, so abuse 'oid'
    conn_timeline oid not null, -- Ditto
    conn_dboid oid not null,  -- This is an oid local to the node_sysid cluster
    conn_local_name name not null
        CHECK(conn_local_name <> ''),
    PRIMARY KEY(conn_sysid, conn_timeline, conn_dboid, conn_local_name),
    -- Wondering why there's no FOREIGN KEY to bdr.bdr_nodes?
    -- It won't be populated until after the connection exists.

    remote_sysid oid,
    remote_timeline oid,
    remote_dboid oid,
    CONSTRAINT remote_ids_all_null_or_all_non_null
        CHECK(remote_sysid IS NULL AND remote_timeline IS NULL AND remote_dboid IS NULL
           OR remote_sysid IS NOT NULL AND remote_timeline IS NOT NULL AND remote_dboid IS NOT NULL),

    conn_replication_name name not null,
    CONSTRAINT conn_replication_name_is_unused
        CHECK(conn_replication_name = ''), -- We don't currently support replication_name on the wire

    conn_dsn text not null,
    conn_init_replica boolean not null default false,
    conn_replica_local_dsn text,
    CHECK(conn_replica_local_dsn IS NOT NULL = conn_init_replica),
    conn_apply_delay integer
        CHECK (conn_apply_delay >= 0),
    conn_replication_sets text[],

    -- XXX DYNCONF temporary hack for BC with config file
    from_config_file boolean not null default 'f'
);

REVOKE ALL ON TABLE bdr_connections FROM public;

CREATE UNIQUE INDEX bdr_connections_only_one_init_replica_conn_per_node
ON bdr_connections(conn_sysid, conn_timeline, conn_dboid)
WHERE (conn_init_replica);

COMMENT ON TABLE bdr_connections IS 'Connections to upstream BDR nodes from this node. Don''t modify this directly, use the provided functions.';

COMMENT ON COLUMN bdr_connections.conn_sysid IS 'Local system identifer for the downstream node in this connection';
COMMENT ON COLUMN bdr_connections.conn_timeline IS 'Local system timeline ID for the downstream node in this connection';
COMMENT ON COLUMN bdr_connections.conn_dboid IS 'Local system database OID for the downstream node in this connection';
COMMENT ON COLUMN bdr_connections.conn_local_name IS 'Name used to identify this connection in application_name, etc. Does not appear in slots.';
COMMENT ON COLUMN bdr_connections.conn_replication_name IS 'Qualifier to distinguish multiple connections to the same remote sysid/tlid/dboid tuple.';
COMMENT ON COLUMN bdr_connections.remote_sysid IS 'Remote end''s system identifier, once connection first established';
COMMENT ON COLUMN bdr_connections.remote_timeline IS 'Remote end''s timeline id, once connection first established';
COMMENT ON COLUMN bdr_connections.remote_dboid IS 'Remote end''s database OID, once connection first established';
COMMENT ON COLUMN bdr_connections.conn_dsn IS 'A libpq-style connection string specifying how to make a connection to the upstream server.';
COMMENT ON COLUMN bdr_connections.conn_init_replica IS 'Internal flag controlling whether the local node should be initialised from data copied from the specified remote node.';
COMMENT ON COLUMN bdr_connections.conn_replica_local_dsn IS 'When copying local state from a remote node during setup, libpq connection string to use to connect to this DB.';
COMMENT ON COLUMN bdr_connections.conn_apply_delay IS 'If set, milliseconds to wait before applying each transaction from the remote node. Mainly for debugging. If null, the global default applies.';
COMMENT ON COLUMN bdr_connections.conn_replication_sets IS 'Replication sets this connection should participate in, if non-default.';

-- We don't exclude bdr_connections with pg_extension_config_dump
-- because this is a global table that's sync'd between nodes.


CREATE FUNCTION bdr_get_local_nodeid( sysid OUT oid, timeline OUT oid, dboid OUT oid)
RETURNS record LANGUAGE c AS 'MODULE_PATHNAME';

-- bdr_get_local_nodeid is intentionally not revoked from all, it's read-only



CREATE FUNCTION bdr_start_perdb_worker()
RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION bdr_start_perdb_worker() FROM public;

COMMENT ON FUNCTION bdr_start_perdb_worker() IS 'Internal BDR function, do not call directly.';



CREATE FUNCTION bdr_connection_add(
    conn_name text, dsn text,
    init_replica boolean DEFAULT false, replica_local_dsn text DEFAULT NULL,
    replication_sets text[] DEFAULT ARRAY['default']
    )
RETURNS void LANGUAGE plpgsql VOLATILE
SET search_path = bdr, pg_catalog
SET bdr.permit_unsafe_ddl_commands = on
SET bdr.skip_ddl_replication = on
SET bdr.skip_ddl_locking = on
AS $$
DECLARE
    v_label json;
    nodeid record;
BEGIN
    LOCK TABLE bdr.bdr_connections IN EXCLUSIVE MODE;

    -- We're doing a read-modify-write on our seclabel entry, so try to avoid
    -- races. This won't lock out writers from other DBs, but we only ever
    -- write to our own.
    LOCK TABLE pg_catalog.pg_shseclabel IN EXCLUSIVE MODE;

    SELECT sysid, timeline, dboid INTO nodeid
    FROM bdr.bdr_get_local_nodeid();

    -- Null/empty checks are skipped, the underlying constraints on the table
    -- will catch that for us.
    INSERT INTO bdr.bdr_connections(
        conn_sysid, conn_timeline, conn_dboid, conn_replication_name,
        conn_local_name, conn_dsn,
        conn_init_replica, conn_replica_local_dsn,
        conn_replication_sets
    )
    VALUES (
        nodeid.sysid, nodeid.timeline, nodeid.dboid, '',
        conn_name, dsn,
        init_replica, replica_local_dsn,
        replication_sets
    );

    -- Is there a current label?
    -- (XXX DYNCONF Right now there's not much point to this check but later
    -- we'll be possibly updating it.)
    SELECT label::json INTO v_label
    FROM pg_catalog.pg_shseclabel
    WHERE provider = 'bdr'
      AND classoid = 'pg_database'::regclass
      AND objoid = (SELECT oid FROM pg_database WHERE datname = current_database());

    -- Inserted without error? Ensure there's a security label on the
    -- database.
    -- TODO DYNCONF: Use something other than a dummy value for the seclabel
    EXECUTE format('SECURITY LABEL FOR bdr ON DATABASE %I IS %L',
                   current_database(), '{"bdr": true}'::json::text);

    -- Now ensure the per-db worker is started if it's not already running.
    -- This won't actually take effect until commit time, it just adds a commit
    -- hook to start the worker when we commit.
    PERFORM bdr.bdr_start_perdb_worker();
END;
$$;

RESET bdr.permit_unsafe_ddl_commands;
RESET bdr.skip_ddl_replication;
RESET search_path;
