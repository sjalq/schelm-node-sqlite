port module Main exposing (main)

import Json.Decode as Json
import Platform
import Schelm.Node.Sqlite as Sqlite
import Schelm.Node.Sqlite.Decode as Decode
import Task


port done : String -> Cmd msg


type alias Job =
    { id : String, body : Json.Value }


type DomainFailure
    = DuplicateJob String
    | InvalidJob String


sqlOrEmpty : String -> Sqlite.Sql
sqlOrEmpty raw =
    Sqlite.sql raw
        |> Result.withDefault
            (Sqlite.sql "SELECT 1"
                |> Result.withDefault (unsafeValue ())
            )


jsonValue : Decode.Decoder Json.Value
jsonValue =
    Decode.string
        |> Decode.andThen
            (\raw ->
                case Json.decodeString Json.value raw of
                    Ok value ->
                        Decode.succeed value

                    Err _ ->
                        Decode.fail "invalid job JSON"
            )


jobDecoder : Decode.Decoder Job
jobDecoder =
    Decode.map2 Job
        (Decode.field "id" Decode.string)
        (Decode.field "job_json" jsonValue)


findJob : String -> Sqlite.Query Job
findJob id =
    Sqlite.query
        (sqlOrEmpty "SELECT id, job_json FROM jobs WHERE id = ?")
        (Sqlite.bindings [ Sqlite.text id ])
        jobDecoder


insertJob : String -> String -> Sqlite.Command
insertJob id raw =
    Sqlite.command
        (sqlOrEmpty "INSERT INTO jobs(id, job_json) VALUES(?, ?)")
        (Sqlite.bindings [ Sqlite.text id, Sqlite.text raw ])


workflow : Sqlite.TransactionProgram DomainFailure String
workflow =
    Sqlite.transactionExecute (insertJob "a" "{}")
        |> Sqlite.transactionAndThen
            (\changes ->
                if changes.changedRows == 1 then
                    Sqlite.transactionQueryOne (findJob "a")

                else
                    Sqlite.transactionFail (InvalidJob "insert count")
            )
        |> Sqlite.transactionAndThen (\job -> Sqlite.transactionSucceed job.id)


allJobs : Sqlite.Options -> Sqlite.CollectionLimit -> Task.Task Sqlite.Error (List Job)
allJobs db limit =
    Sqlite.queryAll db limit
        (Sqlite.query
            (sqlOrEmpty "SELECT id, job_json FROM jobs")
            Sqlite.noBindings
            jobDecoder
        )


type Msg
    = Finished


main : Program () () Msg
main =
    Platform.worker
        { init =
            \_ ->
                let
                    db =
                        Sqlite.options Sqlite.memory

                    limit =
                        Sqlite.collectionLimit 100 100000
                            |> Result.withDefault (unsafeValue ())
                in
                ( ()
                , Task.perform (always Finished)
                    (Sqlite.transaction db Sqlite.Immediate workflow)
                )
        , update = \_ model -> ( model, done "ok" )
        , subscriptions = \_ -> Sub.none
        }


unsafeValue : () -> a
unsafeValue unit =
    unsafeValue unit
