# 07 — Execution-manager addendum

Status: final topology correction before production code. This supersedes every public `Task` execution signature in 05 and the API contract fixture. All declarative data, process, protocol, bound, outcome, and test decisions in 05/06 remain in force.

## 1. Why `Cmd`, not public `Task`

Elm `Task` effects are interpreted by kernel JS/Scheduler. A package-owned parent Elm effect manager can own only a package `Cmd`/`Sub` effect. Therefore a public `Task` API would put the pool, queue, cancellation, and settlement authority in JS and contradict the final design.

V1 execution is callback-based `Cmd`. Kernel `Task` values are private manager verbs only (start supervisor, framed write, await fact, signal/reap); they never own application operation lifecycle or escape publicly.

## 2. Public execution API

```elm
type Operation                         -- opaque manager-issued cancellation key

type alias Callbacks a msg =
    { onStarted : Operation -> msg
    , onFinished : Operation -> Result Error a -> msg
    }

execute : Callbacks Changes msg -> Options -> Command -> Cmd msg
queryAll : Callbacks (List a) msg -> Options -> CollectionLimit -> Query a -> Cmd msg
queryOne : Callbacks a msg -> Options -> Query a -> Cmd msg
queryMaybe : Callbacks (Maybe a) msg -> Options -> Query a -> Cmd msg

transaction :
    Callbacks (Result (TransactionFailure domainError) a) msg
    -> Options
    -> TransactionMode
    -> TransactionProgram domainError a
    -> Cmd msg

cancel : Operation -> Cmd msg
```

`onStarted` is delivered only after the manager has accepted the operation into its physically bounded queue and minted the opaque key. Admission rejection has no key and is delivered through `onFinished` using an internal pre-start sentinel; to avoid that impossible callback ordering, the frozen choice is: `onStarted` is always delivered first for every submitted command, and `AdmissionRejected` may immediately follow as `onFinished`. The operation is already absent by then. Calling `cancel` on absent/stale keys is an idempotent no-op.

Exactly one `onFinished` follows each `onStarted`, unless the owning Elm application itself terminates. Cancellation before physical dispatch finishes `CancelledBeforeDispatch`; after dispatch it follows the uncertainty rules. Callback delivery acknowledgement (`Platform.sendToApp` completion) is distinct from constructing/scheduling the message. The manager deletes operation state only in the same transition that acknowledges terminal callback delivery.

## 3. Existential result erasure

Elm cannot store heterogeneous `Query a` requests directly in one manager state. The public module compiles each operation before issuing the manager command:

- query retains `Decoder a` in closures that turn tagged rows into `Result Error a`;
- the caller callback turns that result into `msg`;
- transaction program is CPS-compiled into private manager instructions whose continuations produce manager actions and ultimately one `msg`;
- resource identities never enter those closures.

The private effect module receives `Request msg`, not `Request a`. Its constructors are package-internal and each already knows how to turn a raw protocol fact into either the next internal instruction or the terminal application message. No `a` is stored existentially and no decoder crosses JS/IPC.

## 4. Manager command and `Cmd.map` law

```elm
effect module Schelm.Node.Sqlite.Manager where { command = MyCmd }

type MyCmd msg
    = Submit (Request msg)
    | Cancel Operation
```

`cmdMap` recursively maps **every** application-message producer:

- `onStarted`;
- terminal success/error callbacks;
- query row/decode continuations;
- transaction success/domain-failure/SQL-failure continuations;
- any queued callback already inside a private request.

It does not alter ids, SQL, values, options, limits, queue position, or protocol facts.

Executable laws:

```text
Cmd.map identity cmd ≡ cmd
Cmd.map (f >> g) cmd ≡ Cmd.map g (Cmd.map f cmd)
```

Equivalence is tested by manager traces and delivered messages, not structural equality of functions. Mapping cannot duplicate/drop effects or change admission/fairness.

## 5. Exact ownership

Parent Elm manager owns:

- database-key normalization already proven in pure Elm;
- operation/request/internal resource ids;
- ≤8-worker pool, physical queues, admission, FIFO and deficit round-robin;
- one in-flight/database and transaction/collection exclusivity;
- decoder and transaction-program interpretation;
- operation phase and potentially-mutating classification;
- cancellation policy, uncertainty classification, callback settlement;
- idle eviction and generation rotation decisions.

Kernel JS owns only facts/verbs:

- create supervisor process and return generation/process facts;
- perform versioned two-hop framed transport with structural caps/credits;
- report entered/row/done/error/autocommit/exit/RSS facts;
- signal/reap a manager-selected generation;
- monotonic deadline/RSS sampling facts.

Supervisor and worker do not choose retry, admission, queue order, callback, migration, or unknown-outcome policy.

## 6. Parent/worker protocol integration

The manager dispatches at most one internal request to a database generation. Kernel callback facts are routed to the effect manager through private scheduler tasks/self messages carrying the complete generation/id tuple. The manager matches the one expected constructor before responding. It sends one-row demand only after the prior row was decoded/disposed and both transport-hop credits were returned.

When an application command disappears from a later `onEffects` batch, nothing is inferred: `Cmd` is an event, not a subscription. Ownership persists in manager state until terminal callback or explicit `cancel`.

## 7. Ordinary recipes

```elm
type Msg
    = JobStarted Sqlite.Operation
    | JobLoaded Sqlite.Operation (Result Sqlite.Error (Maybe Job))
    | SaveStarted Sqlite.Operation
    | Saved Sqlite.Operation (Result Sqlite.Error (Result (Sqlite.TransactionFailure SaveError) Job))

loadJob db id =
    Sqlite.queryMaybe
        { onStarted = JobStarted
        , onFinished = JobLoaded
        }
        db
        (jobById id)

saveJob db job =
    Sqlite.transaction
        { onStarted = SaveStarted
        , onFinished = Saved
        }
        db
        Sqlite.Immediate
        (saveProgram job)
```

A fire-and-report helper is ordinary Elm:

```elm
execute callbacks db command
```

There is no mandatory operation registry in application models unless the application wants cancellation. `onStarted = always IgnoredStart` is valid. A convenience `callbacks : (Result Error a -> msg) -> Callbacks a msg` may synthesize an ignored-start message only when the caller supplies it; the package never hides callback order.

## 8. Tests and gate

The API contract fixture must compile debug/optimize with these `Cmd` signatures and model `Cmd.map`. Manager tests add callback order, one terminal, map laws, cancel-before/after-dispatch, app callback acknowledgement, and 200-session operation ownership.

No production implementation starts until this addendum is committed/pushed. No harness integration starts before final package self-audit and independent audit acceptance.
