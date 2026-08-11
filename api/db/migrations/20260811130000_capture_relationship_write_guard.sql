-- +goose Up

-- Relationship writers from older API binaries do not know about the
-- per-user archive guard. Put the shared half in the database so a rolling
-- deployment cannot race a new archive restore into link+dismissal state.
-- +goose StatementBegin
CREATE FUNCTION acquire_capture_relationship_write_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  guarded_user_id UUID;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF TG_TABLE_NAME = 'retrieval_dismissals' THEN
      IF OLD.surface <> 'related' THEN
        RETURN OLD;
      END IF;
    END IF;
    guarded_user_id := OLD.user_id;
  ELSE
    IF TG_TABLE_NAME = 'retrieval_dismissals' THEN
      IF NEW.surface <> 'related' THEN
        RETURN NEW;
      END IF;
    END IF;
    guarded_user_id := NEW.user_id;
  END IF;

  PERFORM pg_advisory_xact_lock_shared(hashtextextended(
    'capture-relationships:' || guarded_user_id::text,
    0
  ));

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;
-- +goose StatementEnd

CREATE TRIGGER capture_links_relationship_write_guard
BEFORE INSERT OR DELETE ON capture_links
FOR EACH ROW EXECUTE FUNCTION acquire_capture_relationship_write_guard();

CREATE TRIGGER related_dismissals_relationship_write_guard
BEFORE INSERT OR DELETE ON retrieval_dismissals
FOR EACH ROW EXECUTE FUNCTION acquire_capture_relationship_write_guard();

-- +goose Down

DROP TRIGGER IF EXISTS related_dismissals_relationship_write_guard
  ON retrieval_dismissals;
DROP TRIGGER IF EXISTS capture_links_relationship_write_guard
  ON capture_links;
DROP FUNCTION IF EXISTS acquire_capture_relationship_write_guard();
