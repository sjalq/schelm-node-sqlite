port module Main exposing (main)

import Json.Encode as Encode
import Platform
import Schelm.Node.Sqlite as Sqlite
import Schelm.Node.Sqlite.Decode as Decode


port emit : Encode.Value -> Cmd msg


type alias Flags =
    { dbPath : String }


type alias Model =
    { database : Sqlite.Database
    , options : Sqlite.Options
    , limit : Sqlite.CollectionLimit
    , phase : Int
    , batchLeft : Int
    }


type Msg
    = Started String Sqlite.Operation
    | Exec String Sqlite.Operation (Result Sqlite.Error Sqlite.Changes)
    | Names String Sqlite.Operation (Result Sqlite.Error (List String))
    | One Sqlite.Operation (Result Sqlite.Error String)
    | MaybeOne Sqlite.Operation (Result Sqlite.Error (Maybe String))
    | Tx Sqlite.Operation (Result Sqlite.Error (Result (Sqlite.TransactionFailure String) Int))
    | BatchExec Sqlite.Operation (Result Sqlite.Error Sqlite.Changes)
    | Closed (Result Sqlite.Error ())


rowName : Decode.Decoder String
rowName =
    Decode.field "name" Decode.string


countDecoder : Decode.Decoder Int
countDecoder =
    Decode.field "n" Decode.int


mustSql : String -> Sqlite.Sql
mustSql raw =
    case Sqlite.sql raw of
        Ok value ->
            value

        Err _ ->
            mustSql "SELECT 1"


main : Program Flags Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }


init : Flags -> ( Model, Cmd Msg )
init flags =
    case ( Sqlite.database flags.dbPath, Sqlite.collectionLimit 100 1048576 ) of
        ( Ok database, Ok limit ) ->
            let
                model =
                    { database = database
                    , options = Sqlite.options database
                    , limit = limit
                    , phase = 0
                    , batchLeft = 0
                    }
            in
            ( model, runPhase 0 model )

        _ ->
            ( { database = Sqlite.memory
              , options = Sqlite.options Sqlite.memory
              , limit = fallbackLimit ()
              , phase = -1
              , batchLeft = 0
              }
            , emitLine "setup" "Err" (Encode.string "invalid database path or collection limit")
            )


fallbackLimit : () -> Sqlite.CollectionLimit
fallbackLimit _ =
    case Sqlite.collectionLimit 1 1 of
        Ok value ->
            value

        Err _ ->
            fallbackLimit ()


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Started _ _ ->
            ( model, Cmd.none )

        Exec op _ result ->
            finish model op (changesValue result) (advance model)

        Names op _ result ->
            finish model op (namesValue result) (advance model)

        One _ result ->
            finish model "queryOne" (oneValue result) (advance model)

        MaybeOne _ result ->
            finish model "queryMaybe" (maybeValue result) (advance model)

        Tx _ result ->
            finish model "transaction" (txValue result) (advance model)

        BatchExec _ result ->
            case result of
                Err error ->
                    ( model, Cmd.batch [ emitErr "batch" error, closeNow model ] )

                Ok _ ->
                    let
                        left =
                            model.batchLeft - 1
                    in
                    if left <= 0 then
                        let
                            next =
                                { model | batchLeft = 0, phase = 9 }
                        in
                        ( next, runPhase 9 next )

                    else
                        ( { model | batchLeft = left }, Cmd.none )

        Closed result ->
            case result of
                Ok _ ->
                    ( { model | phase = 11 }
                    , emitLine "close" "Ok" (Encode.string "()")
                    )

                Err error ->
                    ( model, emitErr "close" error )


finish : Model -> String -> ( String, Encode.Value ) -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
finish model op encoded ( next, cmd ) =
    case encoded of
        ( "Err", detail ) ->
            ( model, Cmd.batch [ emitLine op "Err" detail, closeNow model ] )

        ( _, detail ) ->
            ( next, Cmd.batch [ emitLine op "Ok" detail, cmd ] )


advance : Model -> ( Model, Cmd Msg )
advance model =
    let
        phase =
            model.phase + 1

        next =
            if phase == 8 then
                { model | phase = phase, batchLeft = 2 }

            else
                { model | phase = phase }
    in
    ( next, runPhase next.phase next )


runPhase : Int -> Model -> Cmd Msg
runPhase phase model =
    case phase of
        0 ->
            execute "execute.create" model (mustSql "CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)") Sqlite.noBindings

        1 ->
            execute "execute.create-batch" model (mustSql "CREATE TABLE IF NOT EXISTS batch (name TEXT NOT NULL)") Sqlite.noBindings

        2 ->
            execute "execute.insert" model (mustSql "INSERT INTO items (name) VALUES (?)") (Sqlite.bindings [ Sqlite.text "alpha" ])

        3 ->
            Sqlite.queryAll
                { onStarted = Started "queryAll", onFinished = Names "queryAll" }
                model.options
                model.limit
                (Sqlite.query (mustSql "SELECT name FROM items ORDER BY id") Sqlite.noBindings rowName)

        4 ->
            Sqlite.queryOne
                { onStarted = Started "queryOne", onFinished = One }
                model.options
                (Sqlite.query (mustSql "SELECT name FROM items WHERE id = ?") (Sqlite.bindings [ Sqlite.int 1 ]) rowName)

        5 ->
            Sqlite.queryMaybe
                { onStarted = Started "queryMaybe", onFinished = MaybeOne }
                model.options
                (Sqlite.query (mustSql "SELECT name FROM items WHERE id = ?") (Sqlite.bindings [ Sqlite.int 999 ]) rowName)

        6 ->
            Sqlite.transaction
                { onStarted = Started "transaction", onFinished = Tx }
                model.options
                Sqlite.Immediate
                txProgram

        7 ->
            execute "execute.after-tx" model (mustSql "INSERT INTO items (name) VALUES (?)") (Sqlite.bindings [ Sqlite.text "gamma" ])

        8 ->
            Cmd.batch
                [ execute "batch.first" model (mustSql "INSERT INTO batch (name) VALUES (?)") (Sqlite.bindings [ Sqlite.text "first" ])
                , execute "batch.second" model (mustSql "INSERT INTO batch (name) VALUES (?)") (Sqlite.bindings [ Sqlite.text "second" ])
                ]

        9 ->
            Sqlite.queryAll
                { onStarted = Started "batch.order", onFinished = Names "batch.order" }
                model.options
                model.limit
                (Sqlite.query (mustSql "SELECT name FROM batch ORDER BY rowid") Sqlite.noBindings rowName)

        10 ->
            closeNow model

        _ ->
            Cmd.none


txProgram : Sqlite.TransactionProgram String Int
txProgram =
    Sqlite.transactionExecute
        (Sqlite.command (mustSql "INSERT INTO items (name) VALUES (?)") (Sqlite.bindings [ Sqlite.text "beta" ]))
        |> Sqlite.transactionAndThen
            (\_ ->
                Sqlite.transactionQueryOne
                    (Sqlite.query (mustSql "SELECT COUNT(*) AS n FROM items") Sqlite.noBindings countDecoder)
            )


execute : String -> Model -> Sqlite.Sql -> Sqlite.Bindings -> Cmd Msg
execute op model sql bindings =
    Sqlite.execute
        { onStarted = Started op
        , onFinished =
            if String.startsWith "batch." op then
                BatchExec

            else
                Exec op
        }
        model.options
        (Sqlite.command sql bindings)


closeNow : Model -> Cmd Msg
closeNow model =
    Sqlite.close model.database Closed


emitLine : String -> String -> Encode.Value -> Cmd msg
emitLine op outcome detail =
    emit
        (Encode.object
            [ ( "op", Encode.string op )
            , ( "outcome", Encode.string outcome )
            , ( "detail", detail )
            ]
        )


emitErr : String -> Sqlite.Error -> Cmd msg
emitErr op error =
    emitLine op "Err" (errorValue error)


errorValue : Sqlite.Error -> Encode.Value
errorValue error =
    Encode.object
        [ ( "kind", Encode.string (kindName (Sqlite.errorKind error)) )
        , ( "message", Encode.string (Sqlite.errorMessage error) )
        , ( "code", Encode.int (Sqlite.errorCode error) )
        ]


changesValue : Result Sqlite.Error Sqlite.Changes -> ( String, Encode.Value )
changesValue result =
    case result of
        Err error ->
            ( "Err", errorValue error )

        Ok changes ->
            ( "Ok"
            , Encode.object
                [ ( "changedRows", Encode.int changes.changedRows )
                , ( "lastInsertRowId"
                  , Encode.string
                        (changes.lastInsertRowId
                            |> Maybe.map Sqlite.int64ToDecimal
                            |> Maybe.withDefault "0"
                        )
                  )
                ]
            )


namesValue : Result Sqlite.Error (List String) -> ( String, Encode.Value )
namesValue result =
    case result of
        Err error ->
            ( "Err", errorValue error )

        Ok names ->
            ( "Ok", Encode.list Encode.string names )


oneValue : Result Sqlite.Error String -> ( String, Encode.Value )
oneValue result =
    case result of
        Err error ->
            ( "Err", errorValue error )

        Ok name ->
            ( "Ok", Encode.string name )


maybeValue : Result Sqlite.Error (Maybe String) -> ( String, Encode.Value )
maybeValue result =
    case result of
        Err error ->
            ( "Err", errorValue error )

        Ok Nothing ->
            ( "Ok", Encode.null )

        Ok (Just name) ->
            ( "Ok", Encode.string name )


txValue : Result Sqlite.Error (Result (Sqlite.TransactionFailure String) Int) -> ( String, Encode.Value )
txValue result =
    case result of
        Err error ->
            ( "Err", errorValue error )

        Ok (Err (Sqlite.DomainFailure reason)) ->
            ( "Err", Encode.string ("domain:" ++ reason) )

        Ok (Err (Sqlite.SqlFailure error)) ->
            ( "Err", errorValue error )

        Ok (Ok count) ->
            ( "Ok", Encode.int count )


kindName : Sqlite.ErrorKind -> String
kindName kind =
    case kind of
        Sqlite.InvalidSql ->
            "InvalidSql"

        Sqlite.BindingMismatch ->
            "BindingMismatch"

        Sqlite.AdmissionRejected ->
            "AdmissionRejected"

        Sqlite.Busy ->
            "Busy"

        Sqlite.Locked ->
            "Locked"

        Sqlite.Constraint ->
            "Constraint"

        Sqlite.SchemaChanged ->
            "SchemaChanged"

        Sqlite.Corrupt ->
            "Corrupt"

        Sqlite.ReadOnlyError ->
            "ReadOnlyError"

        Sqlite.DecodeFailed ->
            "DecodeFailed"

        Sqlite.NoRows ->
            "NoRows"

        Sqlite.TooManyRows ->
            "TooManyRows"

        Sqlite.LimitExceeded ->
            "LimitExceeded"

        Sqlite.CancelledBeforeDispatch ->
            "CancelledBeforeDispatch"

        Sqlite.Interrupted ->
            "Interrupted"

        Sqlite.OperationOutcomeUnknown ->
            "OperationOutcomeUnknown"

        Sqlite.TransactionOutcomeUnknown ->
            "TransactionOutcomeUnknown"

        Sqlite.ProtocolFailure ->
            "ProtocolFailure"

        Sqlite.WorkerMemoryExceeded ->
            "WorkerMemoryExceeded"

        Sqlite.UnsupportedRuntime ->
            "UnsupportedRuntime"

        Sqlite.IoFailure ->
            "IoFailure"
