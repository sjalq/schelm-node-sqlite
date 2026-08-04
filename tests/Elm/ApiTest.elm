module Elm.ApiTest exposing (tests)

import Expect
import Schelm.Node.Sqlite as Sqlite
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "pure API"
        [ test "rejects transaction control" <|
            \_ ->
                Sqlite.sql "BEGIN"
                    |> Expect.equal (Err Sqlite.TransactionControlRejected)
        , describe "signed Int64 decimal"
            [ accepts "0"
            , accepts "1"
            , accepts "-1"
            , accepts "9223372036854775807"
            , accepts "-9223372036854775808"
            , rejects "9223372036854775808"
            , rejects "-9223372036854775809"
            , rejects "99999999999999999999999999999999999999999999999999"
            , rejects "-99999999999999999999999999999999999999999999999999"
            , rejects "00"
            , rejects "01"
            , rejects "-01"
            , rejects "+1"
            , rejects "-0"
            , rejects ""
            , rejects " 1"
            , rejects "1 "
            , rejects "1x"
            ]
        ]


accepts raw =
    test ("accepts " ++ raw) <|
        \_ ->
            Sqlite.int64FromDecimal raw
                |> Result.map Sqlite.int64ToDecimal
                |> Expect.equal (Ok raw)


rejects raw =
    test ("rejects " ++ raw) <|
        \_ ->
            Sqlite.int64FromDecimal raw
                |> Expect.equal (Err Sqlite.InvalidInt64)
