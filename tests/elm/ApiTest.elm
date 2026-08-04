module ApiTest exposing (tests)
import Expect
import Schelm.Node.Sqlite as Sqlite
import Test exposing (..)
tests = describe "pure API" [ test "rejects transaction control" <| \_ -> Sqlite.sql "BEGIN" |> Expect.equal (Err Sqlite.TransactionControlRejected), test "exact max int64" <| \_ -> Sqlite.int64FromDecimal "9223372036854775807" |> Result.map Sqlite.int64ToDecimal |> Expect.equal (Ok "9223372036854775807") ]
