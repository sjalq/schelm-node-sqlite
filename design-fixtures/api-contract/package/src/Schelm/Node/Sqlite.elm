module Schelm.Node.Sqlite exposing
    ( Database, database, memory, ShapeError(..), Sql, sql, Value, null, int, int64, float, text, blob
    , Int64, int64FromDecimal, int64ToDecimal, int64FromInt, int64ToInt
    , Bindings, noBindings, bindings, Command, command, Query, query
    , Options, options, BusyTimeout, busyTimeout, withBusyTimeout, readOnly
    , CollectionLimit, collectionLimit, Changes
    , execute, queryAll, queryOne, queryMaybe
    , TransactionMode(..), TransactionProgram, TransactionFailure(..)
    , transaction, transactionSucceed, transactionFail, transactionMap, transactionAndThen
    , transactionExecute, transactionQueryAll, transactionQueryOne, transactionQueryMaybe
    , Error, ErrorKind(..)
    )
import Bytes exposing (Bytes)
import Schelm.Node.Sqlite.Decode as Decode
import Schelm.Node.Sqlite.Internal as Internal
import Task exposing (Task)
type Database = Database String
type ShapeError = Empty | ContainsNul | InvalidBound
database s = if String.isEmpty s then Err Empty else Ok (Database s)
memory = Database ":memory:contract"
type Sql = Sql String
sql s = if String.isEmpty s then Err Empty else Ok (Sql s)
type alias Int64 = Internal.Int64
int64FromDecimal s = if String.isEmpty s then Err InvalidBound else Ok (Internal.Int64 s)
int64ToDecimal (Internal.Int64 s) = s
int64FromInt n = Internal.Int64 (String.fromInt n)
int64ToInt (Internal.Int64 s) = String.toInt s
type alias Value = Internal.Value
null = Internal.Null
int = int64FromInt >> Internal.Integer
int64 = Internal.Integer
float = Internal.Real
text = Internal.Text
blob = Internal.Blob
type Bindings = Bindings (List Value)
noBindings = Bindings []
bindings = Bindings
type Command = Command Sql Bindings
command = Command
type Query a = Query Sql Bindings (Decode.Decoder a)
query = Query
type BusyTimeout = BusyTimeout Int
busyTimeout n = if n < 0 then Err InvalidBound else Ok (BusyTimeout n)
type Options = Options Database
options = Options
withBusyTimeout _ o = o
readOnly o = o
type CollectionLimit = CollectionLimit Int Int
collectionLimit r b = if r < 1 || b < 1 then Err InvalidBound else Ok (CollectionLimit r b)
type alias Changes = { changedRows : Int, lastInsertRowId : Maybe Int64 }
type Error = Error ErrorKind
type ErrorKind = InvalidSql | BindingMismatch | Busy | OperationOutcomeUnknown | TransactionOutcomeUnknown | UnsupportedRuntime
execute _ _ = Task.fail (Error UnsupportedRuntime)
queryAll _ _ _ = Task.fail (Error UnsupportedRuntime)
queryOne _ _ = Task.fail (Error UnsupportedRuntime)
queryMaybe _ _ = Task.fail (Error UnsupportedRuntime)
type TransactionMode = Deferred | Immediate | Exclusive
type TransactionProgram e a = Tx a
type TransactionFailure e = DomainFailure e
transaction _ _ (Tx a) = Task.succeed (Ok a)
transactionSucceed = Tx
transactionFail _ = Tx (unsafeValue ())
transactionMap f (Tx a) = Tx (f a)
transactionAndThen f (Tx a) = f a
transactionExecute _ = Tx { changedRows = 0, lastInsertRowId = Nothing }
transactionQueryAll _ _ = Tx []
transactionQueryOne _ = Tx (unsafeValue ())
transactionQueryMaybe _ = Tx Nothing

unsafeValue : () -> a
unsafeValue unit = unsafeValue unit
