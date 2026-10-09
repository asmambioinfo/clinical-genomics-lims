-- Migration 0002: allow 'Deleted' as an orders.status value (soft delete).
-- The original CHECK constraint was unnamed, so look up its generated name
-- before dropping it, then re-add it under a stable name.

DECLARE @cname NVARCHAR(256);
SELECT @cname = cc.name
FROM sys.check_constraints cc
JOIN sys.columns c
  ON cc.parent_object_id = c.object_id AND cc.parent_column_id = c.column_id
WHERE cc.parent_object_id = OBJECT_ID('orders') AND c.name = 'status';

IF @cname IS NOT NULL
    EXEC('ALTER TABLE orders DROP CONSTRAINT ' + @cname);

ALTER TABLE orders ADD CONSTRAINT ck_orders_status
    CHECK (status IN ('Pending', 'Running', 'Completed', 'Failed', 'Cancelled', 'Deleted'));
