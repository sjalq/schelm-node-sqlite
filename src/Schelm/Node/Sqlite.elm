module Schelm.Node.Sqlite exposing
    ( Database, ShapeError(..), database, memory, Options, options, readOnly
    , BusyTimeout, busyTimeout, withBusyTimeout, Sql, sql
    , Int64, int64FromDecimal, int64ToDecimal, int64FromInt, int64ToInt
    , Value, null, int, int64, float, text, blob, Bindings, noBindings, bindings
    , Command, command, Query, query, CollectionLimit, collectionLimit
    , Operation, Callbacks, Changes, Error, ErrorKind(..)
    , TransactionMode(..), TransactionProgram, TransactionFailure(..)
    , transactionSucceed, transactionFail, transactionMap, transactionAndThen
    , transactionExecute, transactionQueryOne
    )

import Bytes exposing (Bytes)
import Schelm.Node.Sqlite.Decode as Decode
import Schelm.Node.Sqlite.Internal as Internal


type Database = FileDatabase String | MemoryDatabase String

type ShapeError = Empty | ContainsNul | InvalidBound | InvalidInt64 | TransactionControlRejected

type Options = Options { database : Database, readOnly : Bool, busyTimeout : Int }

type alias BusyTimeout = Int

type alias Sql = String

type alias Int64 = Internal.Int64

type alias Value = Internal.Value

type alias Bindings = Internal.Bindings

type alias Command = Internal.Command

type alias Query a = Internal.Query a

type CollectionLimit = CollectionLimit { rows : Int, bytes : Int }

type Operation = Operation Int

type alias Callbacks a msg = { onStarted : Operation -> msg, onFinished : Operation -> Result Error a -> msg }

type alias Changes = { changedRows : Int, lastInsertRowId : Maybe Int64 }

type Error = Error ErrorKind String Int

type ErrorKind = InvalidSql | BindingMismatch | AdmissionRejected | Busy | Locked | Constraint | SchemaChanged | Corrupt | ReadOnlyError | DecodeFailed | NoRows | TooManyRows | LimitExceeded | CancelledBeforeDispatch | Interrupted | OperationOutcomeUnknown | TransactionOutcomeUnknown | ProtocolFailure | WorkerMemoryExceeded | UnsupportedRuntime | IoFailure

type TransactionMode = Deferred | Immediate | Exclusive

type TransactionFailure domainError = DomainFailure domainError | SqlFailure Error

type TransactionProgram domainError a
    = TransactionProgram ((a -> TransactionStep) -> (domainError -> TransactionStep) -> TransactionStep)

type TransactionStep
    = TransactionDone
    | TransactionCommand Command (Changes -> TransactionStep)
    | TransactionOne String Bindings (Internal.Row -> Result Decode.Error TransactionStep)


database raw = if String.isEmpty raw then Err Empty else if String.contains "\u{0000}" raw then Err ContainsNul else Ok (FileDatabase raw)
memory = MemoryDatabase "default"
options db = Options { database = db, readOnly = False, busyTimeout = 5000 }
readOnly (Options config) = Options { config | readOnly = True }
busyTimeout millis = if millis < 0 || millis > 60000 then Err InvalidBound else Ok millis
withBusyTimeout timeout (Options config) = Options { config | busyTimeout = timeout }

sql raw =
    if String.isEmpty (String.trim raw) then Err Empty
    else if String.contains "\u{0000}" raw then Err ContainsNul
    else if isTransactionControl raw then Err TransactionControlRejected
    else Ok raw

isTransactionControl raw =
    case String.words (String.toUpper raw) |> List.head of
        Just first -> List.any ((==) first) [ "BEGIN", "COMMIT", "END", "ROLLBACK", "SAVEPOINT", "RELEASE" ]
        Nothing -> False

int64FromDecimal raw = if canonical raw then Ok (Internal.Int64 raw) else Err InvalidInt64
int64ToDecimal (Internal.Int64 raw) = raw
int64FromInt n = Internal.Int64 (String.fromInt n)
int64ToInt (Internal.Int64 raw) = String.toInt raw
canonical raw =
    case String.toInt raw of
        Just _ -> not (String.startsWith "+" raw) && raw /= "-0" && (raw == "0" || not (String.startsWith "0" raw))
        Nothing -> raw == "9223372036854775807" || raw == "-9223372036854775808"

null = Internal.Null
int = int64FromInt >> Internal.Integer
int64 = Internal.Integer
float = Internal.Real
text = Internal.Text
blob = Internal.Blob
noBindings = Internal.Bindings []
bindings = Internal.Bindings
command = Internal.Command
query = Internal.Query
collectionLimit rows bytes_ = if rows < 1 || rows > 100000 || bytes_ < 1 || bytes_ > 8388608 then Err InvalidBound else Ok (CollectionLimit { rows = rows, bytes = bytes_ })

transactionSucceed value_ = TransactionProgram (\onSuccess _ -> onSuccess value_)
transactionFail error = TransactionProgram (\_ onFailure -> onFailure error)
transactionMap fn program = transactionAndThen (fn >> transactionSucceed) program
transactionAndThen fn (TransactionProgram run) =
    TransactionProgram
        (\onSuccess onFailure ->
            run
                (\value_ ->
                    let
                        (TransactionProgram next) = fn value_
                    in
                    next onSuccess onFailure
                )
                onFailure
        )
transactionExecute command_ =
    TransactionProgram (\onSuccess _ -> TransactionCommand command_ onSuccess)
transactionQueryOne (Internal.Query source bindValues decoder) =
    TransactionProgram
        (\onSuccess _ ->
            TransactionOne source bindValues
                (\row -> Internal.decode decoder row |> Result.map onSuccess)
        )
