module Schelm.Node.Sqlite.Int64 exposing (canonical)


canonical raw =
    if raw == "0" then
        True

    else if String.startsWith "-" raw then
        let
            magnitude =
                String.dropLeft 1 raw
        in
        not (String.isEmpty magnitude)
            && not (String.startsWith "0" magnitude)
            && decimalDigits magnitude
            && withinMagnitude "9223372036854775808" magnitude

    else
        not (String.isEmpty raw)
            && not (String.startsWith "0" raw)
            && decimalDigits raw
            && withinMagnitude "9223372036854775807" raw


withinMagnitude maximum candidate =
    let
        candidateLength =
            String.length candidate

        maximumLength =
            String.length maximum
    in
    candidateLength < maximumLength
        || (candidateLength == maximumLength && candidate <= maximum)


decimalDigits raw =
    raw
        |> String.toList
        |> List.all (\character -> character >= '0' && character <= '9')
