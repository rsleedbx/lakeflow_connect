DECLARE @STATE_DESC varchar(max), @WAIT_COUNT int=0
select @STATE_DESC=state_desc from sys.databases where name='${DB_DB}'
WHILE (@STATE_DESC != 'ONLINE' and @WAIT_COUNT < 10)
BEGIN
  WAITFOR DELAY '00:00:30'
  select @STATE_DESC=state_desc from sys.databases where name='${DB_DB}'
  SET  @WAIT_COUNT = @WAIT_COUNT + 1
END 
SELECT @STATE_DESC, @WAIT_COUNT 
GO