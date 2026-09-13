module Schelm.Node.Sqlite exposing
    ( Database, ShapeError(..), database, memory, Options, options, readOnly
    , BusyTimeout, busyTimeout, withBusyTimeout, Sql, sql
    , Int64, int64FromDecimal, int64ToDecimal, int64FromInt, int64ToInt
    , Value, null, int, int64, float, text, blob, Bindings, noBindings, bindings
    , Command, command, Query, query, CollectionLimit, collectionLimit
    , Operation, Callbacks, Changes, Error, ErrorKind(..)
    , errorKind, errorMessage, errorCode
    , execute, queryAll, queryOne, queryMaybe, transaction, cancel, close
    , TransactionMode(..), TransactionProgram, TransactionFailure(..)
    , transactionSucceed, transactionFail, transactionMap, transactionAndThen
    , transactionExecute, transactionQueryOne
    )

import Bytes exposing (Bytes)
import Bytes.Decode as BytesDecode
import Bytes.Encode
import Json.Encode as Encode
import Schelm.Node.Sqlite.Manager as Manager
import Schelm.Node.Sqlite.Internal.Runtime as Runtime
import Task
import Schelm.Node.Sqlite.Decode as Decode
import Schelm.Node.Sqlite.Internal as Internal
import Schelm.Node.Sqlite.Int64 as Int64


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

type alias Operation = Manager.Operation

type alias Callbacks a msg = { onStarted : Operation -> msg, onFinished : Operation -> Result Error a -> msg }

type alias Changes = { changedRows : Int, lastInsertRowId : Maybe Int64 }

type Error = Error ErrorKind String Int

type ErrorKind = InvalidSql | BindingMismatch | AdmissionRejected | Busy | Locked | Constraint | SchemaChanged | Corrupt | ReadOnlyError | DecodeFailed | NoRows | TooManyRows | LimitExceeded | CancelledBeforeDispatch | Interrupted | OperationOutcomeUnknown | TransactionOutcomeUnknown | ProtocolFailure | WorkerMemoryExceeded | UnsupportedRuntime | IoFailure

type TransactionMode = Deferred | Immediate | Exclusive

type TransactionFailure domainError = DomainFailure domainError | SqlFailure Error

type TransactionProgram domainError a
    = TransactionSucceed a
    | TransactionFail domainError
    | TransactionCommand Command (Changes -> TransactionProgram domainError a)
    | TransactionOne String Bindings (Internal.Row -> Result Decode.Error (TransactionProgram domainError a))


errorKind (Error kind_ _ _) = kind_
errorMessage (Error _ message _) = message
errorCode (Error _ _ code) = code


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

int64FromDecimal raw = if Int64.canonical raw then Ok (Internal.Int64 raw) else Err InvalidInt64
int64ToDecimal (Internal.Int64 raw) = raw
int64FromInt n = Internal.Int64 (String.fromInt n)
int64ToInt (Internal.Int64 raw) = String.toInt raw
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

transactionSucceed value_ = TransactionSucceed value_
transactionFail error = TransactionFail error
transactionMap fn program = transactionAndThen (fn >> transactionSucceed) program
transactionAndThen : (a -> TransactionProgram e b) -> TransactionProgram e a -> TransactionProgram e b
transactionAndThen fn program =
    case program of
        TransactionSucceed value_ ->
            fn value_

        TransactionFail error ->
            TransactionFail error

        TransactionCommand command_ continue ->
            TransactionCommand command_ (\changes -> transactionAndThen fn (continue changes))

        TransactionOne source bindValues decodeContinue ->
            TransactionOne source bindValues (\row -> Result.map (transactionAndThen fn) (decodeContinue row))
transactionExecute command_ =
    TransactionCommand command_ TransactionSucceed
transactionQueryOne (Internal.Query source bindValues decoder) =
    TransactionOne source bindValues
        (\row -> Internal.decode decoder row |> Result.map TransactionSucceed)


execute : Callbacks Changes msg -> Options -> Command -> Cmd msg
execute callbacks_ options_ command_ =
    submit callbacks_ options_ (executeTask options_ False command_)

queryAll : Callbacks (List a) msg -> Options -> CollectionLimit -> Query a -> Cmd msg
queryAll callbacks_ options_ limit query_ =
    submit callbacks_ options_ (\handle requestId -> queryTask options_ False limit query_ handle requestId |> Task.andThen decodeRows)

queryOne : Callbacks a msg -> Options -> Query a -> Cmd msg
queryOne callbacks_ options_ query_ =
    queryAll
        { onStarted = callbacks_.onStarted
        , onFinished = \operation result -> callbacks_.onFinished operation (result |> Result.andThen exactlyOne)
        }
        options_
        (CollectionLimit { rows = 2, bytes = 8388608 })
        query_

queryMaybe : Callbacks (Maybe a) msg -> Options -> Query a -> Cmd msg
queryMaybe callbacks_ options_ query_ =
    queryAll
        { onStarted = callbacks_.onStarted
        , onFinished = \operation result -> callbacks_.onFinished operation (result |> Result.andThen atMostOne)
        }
        options_
        (CollectionLimit { rows = 2, bytes = 8388608 })
        query_

transaction : Callbacks (Result (TransactionFailure domainError) a) msg -> Options -> TransactionMode -> TransactionProgram domainError a -> Cmd msg
transaction callbacks_ options_ mode program =
    Manager.submit (databaseKey options_) (encodeOptions options_) callbacks_.onStarted
        (\operation -> callbacks_.onFinished operation (Err (Error AdmissionRejected "queue admission rejected" 0)))
        (\operation -> callbacks_.onFinished operation (Err (Error CancelledBeforeDispatch "cancelled before dispatch" 0)))
        (\operation -> callbacks_.onFinished operation (Err (Error TransactionOutcomeUnknown "transaction worker replaced during cancellation" 0)))
        (\operation requestId handle ->
            transactionTask options_ handle requestId mode program
                |> settle callbacks_.onFinished operation
        )

cancel : Operation -> Cmd msg
cancel = Manager.cancel

close : Database -> (Result Error () -> msg) -> Cmd msg
close db toMsg =
    Manager.close (databasePath db) (toMsg (Ok ()))

submit callbacks_ options_ taskFactory =
    Manager.submit (databaseKey options_) (encodeOptions options_) callbacks_.onStarted
        (\operation -> callbacks_.onFinished operation (Err (Error AdmissionRejected "queue admission rejected" 0)))
        (\operation -> callbacks_.onFinished operation (Err (Error CancelledBeforeDispatch "cancelled before dispatch" 0)))
        (\operation -> callbacks_.onFinished operation (Err (Error OperationOutcomeUnknown "dispatched operation cancelled; worker replaced" 0)))
        (\operation requestId handle -> taskFactory handle requestId |> settle callbacks_.onFinished operation)

settle finished operation task =
    task |> Task.map Ok |> Task.onError (Err >> Task.succeed) |> Task.map (finished operation)

executeTask options_ inTransaction (Internal.Command source (Internal.Bindings bindValues)) handle requestId =
    Runtime.request handle (runtimeRequest requestId "execute" (not (isReadOnly options_)) inTransaction source bindValues 1 1 "" (encodeOptions options_))
        |> Task.mapError runtimeError
        |> Task.andThen (\response ->
            case int64FromDecimal response.lastInsertRowId of
                Ok rowId -> Task.succeed { changedRows = response.changedRows, lastInsertRowId = Just rowId }
                Err _ -> Task.fail (Error ProtocolFailure "invalid last insert row id" 0)
        )

queryTask options_ inTransaction (CollectionLimit limits) (Internal.Query source (Internal.Bindings bindValues) decoder) handle requestId =
    Runtime.request handle (runtimeRequest requestId "query" (not (isReadOnly options_)) inTransaction source bindValues limits.rows limits.bytes "" (encodeOptions options_))
        |> Task.mapError runtimeError
        |> Task.map (\response -> ( decoder, response.columns, response.rows ))

decodeRows ( decoder, columns, rows ) =
    rows
        |> List.foldr
            (\wire accumulated ->
                Result.map2 (::) (Internal.decode decoder { columns = columns, values = List.map fromWire wire }) accumulated
            )
            (Ok [])
        |> Result.mapError (\problem_ -> Error DecodeFailed problem_.reason 0)
        |> resultTask

transactionTask options_ handle requestId mode program =
    Runtime.request handle (runtimeRequest requestId "begin" True False "" [] 1 1 (modeName mode) (encodeOptions options_))
        |> Task.mapError runtimeError
        |> Task.onError (\error -> rollbackQuiet handle (requestId + 1) error)
        |> Task.andThen (\_ -> interpretTransaction options_ handle (requestId + 1) 0 program)

interpretTransaction options_ handle requestId instructions program =
    if instructions >= 1000 then
        rollbackThen handle requestId (Task.fail (Error LimitExceeded "transaction instruction limit" 0))
    else
        case program of
            TransactionSucceed value_ ->
                Runtime.request handle (runtimeRequest requestId "commit" True True "" [] 1 1 "" (encodeOptions options_))
                    |> Task.mapError (\_ -> Error TransactionOutcomeUnknown "commit acknowledgement unavailable" 0)
                    |> Task.map (always (Ok value_))

            TransactionFail reason ->
                Runtime.request handle (runtimeRequest requestId "rollback" True True "" [] 1 1 "" (encodeOptions options_))
                    |> Task.mapError (\_ -> Error TransactionOutcomeUnknown "rollback acknowledgement unavailable" 0)
                    |> Task.map (always (Err (DomainFailure reason)))

            TransactionCommand command_ continue ->
                executeTask options_ True command_ handle requestId
                    |> Task.onError (\error -> rollbackThen handle (requestId + 1) (Task.fail error))
                    |> Task.andThen (\changes -> interpretTransaction options_ handle (requestId + 1) (instructions + 1) (continue changes))

            TransactionOne source bindValues decodeContinue ->
                queryTask options_ True (CollectionLimit { rows = 2, bytes = 8388608 }) (Internal.Query source bindValues Decode.value) handle requestId
                    |> Task.onError (\error -> rollbackThen handle (requestId + 1) (Task.fail error))
                    |> Task.andThen
                        (\( _, columns, rows ) ->
                            case rows of
                                [ row ] ->
                                    case decodeContinue { columns = columns, values = List.map fromWire row } of
                                        Ok next -> interpretTransaction options_ handle (requestId + 1) (instructions + 1) next
                                        Err problem_ -> rollbackThen handle (requestId + 1) (Task.fail (Error DecodeFailed problem_.reason 0))
                                [] -> rollbackThen handle (requestId + 1) (Task.fail (Error NoRows "query returned no rows" 0))
                                _ -> rollbackThen handle (requestId + 1) (Task.fail (Error TooManyRows "query returned multiple rows" 0))
                        )

rollbackThen handle requestId terminal =
    Runtime.request handle (runtimeRequest requestId "rollback" True True "" [] 1 1 "" Encode.null)
        |> Task.mapError (\_ -> Error TransactionOutcomeUnknown "rollback acknowledgement unavailable" 0)
        |> Task.andThen (always terminal)

rollbackQuiet handle requestId error =
    Runtime.request handle (runtimeRequest requestId "rollback" True True "" [] 1 1 "" Encode.null)
        |> Task.map (always ())
        |> Task.onError (\_ -> Task.succeed ())
        |> Task.andThen (\_ -> Task.fail error)

exactlyOne values = case values of
    [ value_ ] -> Ok value_
    [] -> Err (Error NoRows "query returned no rows" 0)
    _ -> Err (Error TooManyRows "query returned multiple rows" 0)
atMostOne values = case values of
    [] -> Ok Nothing
    [ value_ ] -> Ok (Just value_)
    _ -> Err (Error TooManyRows "query returned multiple rows" 0)
resultTask result =
    case result of
        Ok value_ -> Task.succeed value_
        Err error -> Task.fail error

runtimeRequest requestId operation mutating inTransaction source bindValues rows bytes_ mode options_ =
    { id = requestId, operation = operation, mutating = mutating, inTransaction = inTransaction
    , sql = source, bindings = List.map encodeValue bindValues, rowLimit = rows, byteLimit = bytes_, mode = mode, options = options_ }

encodeOptions (Options config) =
    Encode.object [ ( "path", Encode.string (databasePath config.database)), ( "readOnly", Encode.bool config.readOnly ), ( "busyTimeout", Encode.int config.busyTimeout ) ]
databasePath db =
    case db of
        FileDatabase path -> path
        MemoryDatabase _ -> ":memory:"
databaseKey (Options config) = databasePath config.database ++ if config.readOnly then "|ro" else "|rw"
isReadOnly (Options config) = config.readOnly
modeName mode =
    case mode of
        Deferred -> "DEFERRED"
        Immediate -> "IMMEDIATE"
        Exclusive -> "EXCLUSIVE"
encodeValue value_ = case value_ of
    Internal.Null -> Encode.object [ ( "t", Encode.string "null" ) ]
    Internal.Integer (Internal.Int64 raw) -> Encode.object [ ( "t", Encode.string "integer" ), ( "v", Encode.string raw ) ]
    Internal.Real raw -> Encode.object [ ( "t", Encode.string "real" ), ( "v", Encode.float raw ) ]
    Internal.Text raw -> Encode.object [ ( "t", Encode.string "text" ), ( "v", Encode.string raw ) ]
    Internal.Blob raw -> Encode.object [ ( "t", Encode.string "blob" ), ( "v", Encode.list Encode.int (bytesList raw) ) ]
fromWire wire = case wire of
    Runtime.WireNull -> Internal.Null
    Runtime.WireInteger raw -> Internal.Integer (Internal.Int64 raw)
    Runtime.WireReal raw -> Internal.Real raw
    Runtime.WireText raw -> Internal.Text raw
    Runtime.WireBlob raw -> Internal.Blob (bytesFromList raw)
bytesList raw = BytesDecode.decode (BytesDecode.loop [] (\rev -> if List.length rev >= Bytes.width raw then BytesDecode.succeed (BytesDecode.Done (List.reverse rev)) else BytesDecode.map (\byte -> BytesDecode.Loop (byte :: rev)) BytesDecode.unsignedInt8)) raw |> Maybe.withDefault []
bytesFromList values = Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.unsignedInt8 values))
runtimeError raw =
    let kind_ = case raw.kind of
            "invalid-sql" -> InvalidSql
            "binding-mismatch" -> BindingMismatch
            "busy" -> Busy
            "locked" -> Locked
            "constraint" -> Constraint
            "schema-changed" -> SchemaChanged
            "corrupt" -> Corrupt
            "read-only" -> ReadOnlyError
            "operation-outcome-unknown" -> OperationOutcomeUnknown
            "transaction-outcome-unknown" -> TransactionOutcomeUnknown
            "protocol-failure" -> ProtocolFailure
            "worker-memory-exceeded" -> WorkerMemoryExceeded
            "unsupported-runtime" -> UnsupportedRuntime
            "interrupted" -> Interrupted
            "limit-exceeded" -> LimitExceeded
            _ -> IoFailure
    in Error kind_ raw.message raw.code
