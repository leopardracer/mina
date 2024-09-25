open Core_kernel

type field = Pickles.Impls.Step.Internal_Basic.field

(* Alias to distinguish hashes from inputs *)
type hash = field

type input_t = [ `State of field Oracle.State.t ] * field array

(** Defines a batching hash monad.contents

    Originally started as a specialized variant of Freer monad.
    See: Oleg Kiselyov, and Hiromi Ishii. “Freer Monads, More Extensible Effects.”
    https://okmij.org/ftp/Haskell/extensible/more.pdf

    For better performance it was encoded using Final tagless technique, and now
    looks quite different from its original inspiration.
*)

type request_t =
  { (* request is a non-empty sequence *)
    request : input_t Sequence.t
  ; request_len : int
  }

type impure_t = request_t -> (hash array -> int -> unit) -> unit

type 'a t = impure:impure_t -> ('a -> unit) -> unit

let empty_request = { request = Sequence.empty; request_len = 0 }

let join_requests areq breq =
  { request = Sequence.append areq.request breq.request
  ; request_len = areq.request_len + breq.request_len
  }

let impure_default : request_t -> (hash array -> int -> unit) -> unit =
 fun { request; request_len; _ } cont ->
  let request = Sequence.(to_list request) in
  let start = Time_ns.now () in
  let response = Oracle.hash_batch request |> Array.of_list in
  printf "Hashing batch of %d requests took %s\n" request_len
    Time_ns.(diff (now ()) start |> Span.to_short_string) ;
  cont response 0

let evaluate : 'a t -> 'a =
 fun v ->
  let res = ref None in
  v ~impure:impure_default (fun r -> res := Some r) ;
  Option.value_exn ~message:"unexpected evaluation" !res

module M_basic = struct
  let bind : type a b. a t -> f:(a -> b t) -> b t =
   fun t ~f ~impure handle_res ->
    t ~impure (fun tres -> f tres ~impure handle_res)

  let return : 'a -> 'a t = fun a ~impure:_ handle -> handle a

  let map : type a b. a t -> f:(a -> b) -> b t =
   fun v ~f ~impure handle_res -> v ~impure (Fn.compose handle_res f)
end

let hash ~init data : hash t =
 fun ~(impure : impure_t) handler ->
  impure
    { request = Sequence.return (`State init, data); request_len = 1 }
    (fun h i -> handler @@ Array.get h i)

let hash_batch data : hash list t =
 fun ~(impure : impure_t) handler ->
  let request_len = List.length data in
  if request_len = 0 then handler []
  else
    impure
      { request = Sequence.of_list data; request_len }
      (fun hashes start_ix ->
        handler
        @@ List.init request_len ~f:(fun i ->
               Array.get hashes @@ (i + start_ix) ) )

let ( <*> ) : type a b. (a -> b) t -> a t -> b t =
 fun f a ~impure handle_res ->
  let a_res_ref = ref None in
  let f_res_ref = ref None in
  let req = ref None in
  let impure_f freq fcont =
    if Option.is_none !req then req := Some (freq, fcont) else impure freq fcont
  in
  let impure_a areq acont =
    let req' = !req in
    req := None ;
    match req' with
    | None ->
        impure areq acont
    | Some (r, c) ->
        impure (join_requests r areq) (fun hashes ix ->
            c hashes ix ;
            acont hashes (r.request_len + ix) )
  in
  f ~impure:impure_f (fun f' ->
      match !a_res_ref with
      | Some a' ->
          handle_res (f' a')
      | None ->
          f_res_ref := Some f' ) ;
  a ~impure:impure_a (fun a' ->
      ( match !f_res_ref with
      | None ->
          a_res_ref := Some a'
      | Some f' ->
          handle_res (f' a') ) ;
      Option.iter !req ~f:(Tuple2.uncurry impure) )

let lift2 f a b ~impure handle = (M_basic.map ~f a <*> b) ~impure handle

let all_impl ~impure ~set_result ~on_ready lst =
  let no_cont _hashes _ix = () in
  let empty_acc = (0, empty_request, no_cont) in
  let active = ref (List.length lst) in
  let req_acc = ref empty_acc in
  let init i action =
    let impure' ireq icont =
      let contributed, req, cont = !req_acc in
      let req' = join_requests req ireq in
      let cont' hashes ix =
        cont hashes ix ;
        icont hashes (req.request_len + ix)
      in
      let contributed' = contributed + 1 in
      if contributed' = !active then (
        req_acc := empty_acc ;
        impure req' cont' )
      else req_acc := (contributed', req', cont')
    in
    action ~impure:impure' (fun a ->
        set_result i a ;
        let active' = !active - 1 in
        active := active' ;
        let contributed, req, cont = !req_acc in
        if active' = 0 then on_ready ()
        else if active' = contributed then (
          req_acc := empty_acc ;
          impure req cont ) )
  in
  List.iteri ~f:init lst

module M : Core_kernel.Monad.S with type 'a t := 'a t = struct
  include M_basic

  module Monad_infix = struct
    let ( >>= ) t f = bind t ~f

    let ( >>| ) t f = map t ~f
  end

  include Monad_infix

  module Let_syntax = struct
    let return = return

    include Monad_infix

    module Let_syntax = struct
      include M_basic

      let both a b = lift2 Tuple2.create a b

      module Open_on_rhs = struct end
    end
  end

  let join t = t >>= ident

  let ignore_m t = map ~f:(const ()) t

  let all : type a. a t list -> a list t =
   fun lst ~impure handle_res ->
    let results = Array.init (List.length lst) ~f:(const None) in
    let set_result i a = Array.set results i (Some a) in
    let on_ready () =
      Array.to_list results
      |> List.map ~f:(fun r ->
             Option.value_exn ~message:"some elements not evaluated" r )
      |> handle_res
    in
    all_impl ~set_result ~impure ~on_ready lst

  let all_unit : unit t list -> unit t =
   fun lst ~impure on_ready ->
    let set_result _ () = () in
    all_impl ~set_result ~impure ~on_ready lst
end

include M

let map_list ~f = Fn.compose all @@ List.map ~f

let fold_right ~f ~init =
  List.fold_right ~init:(return init) ~f:(fun el -> bind ~f:(f el))

module For_tests = struct
  module Counting_executor () = struct
    let calls = ref 0

    let total = ref 0

    let test_impure : 'a. request_t -> (hash array -> int -> unit) -> unit =
     fun { request; _ } cont ->
      calls := !calls + 1 ;
      let total_els =
        Sequence.fold ~init:0 ~f:(fun a (_, b) -> a + Array.length b) request
      in
      total := !total + total_els ;
      let request = Sequence.(to_list request) in
      let response =
        List.map ~f:(Fn.compose (Fn.flip Array.get 0) snd) request
        |> Array.of_list
      in
      cont response 0

    let test_evaluate : 'a t -> 'a =
     fun v ->
      let res = ref None in
      v ~impure:test_impure (fun r -> res := Some r) ;
      Option.value_exn ~message:"unexpected evaluation" !res
  end
end

let%test_module "simple test" =
  ( module struct
    open Snark_params.Tick

    open For_tests.Counting_executor ()

    let init = Oracle.salt "bla"

    let zero = Field.zero

    let one = Field.one

    let two = Field.add one one

    let zeros = Array.init ~f:(const zero)

    let ones = Array.init ~f:(const one)

    let single_zero = zeros 1

    let single_one = ones 1

    let triple_zero = zeros 3

    let triple_one = ones 3

    let ten_zero = zeros 10

    let execute (comp, check, total', calls') =
      total := 0 ;
      calls := 0 ;
      let res = test_evaluate comp in
      check res ;
      [%test_eq: int * int] (!total, !calls) (total', calls') ;
      true

    let comp0 =
      hash ~init single_zero
      >>= fun a -> map ~f:(Tuple2.create a) (hash ~init triple_zero)

    let%test "test0" =
      execute (comp0, [%test_eq: Field.t * Field.t] (zero, zero), 4, 2)

    let comp1 =
      map ~f:Tuple2.create (hash ~init single_zero) <*> hash ~init triple_zero

    let%test "test1" =
      execute (comp1, [%test_eq: Field.t * Field.t] (zero, zero), 4, 1)

    let comp2 =
      map ~f:Tuple3.create (hash ~init single_zero)
      <*> hash ~init ten_zero <*> hash ~init triple_zero

    let%test "test2" =
      execute
        ( comp2
        , [%test_eq: Field.t * Field.t * Field.t] (zero, zero, zero)
        , 14
        , 1 )

    let comp3 = hash ~init single_zero >>= fun _ -> hash ~init single_zero

    let%test "test3" = execute (comp3, [%test_eq: Field.t] zero, 2, 2)

    let comp4 =
      hash ~init single_zero
      >>= fun _ ->
      let%map.M a = hash ~init single_zero and b = hash ~init triple_zero in
      (a, b)

    let%test "test4" =
      execute (comp4, [%test_eq: Field.t * Field.t] (zero, zero), 5, 2)

    let comp5 =
      (let%map.M a = hash ~init single_zero and b = hash ~init triple_zero in
       (a, b) )
      >>= fun (a, b) -> map ~f:(Tuple3.create a b) (hash ~init single_one)

    let%test "test5" =
      execute
        (comp5, [%test_eq: Field.t * Field.t * Field.t] (zero, zero, one), 5, 2)

    let comp6 =
      let%bind.M a, b =
        let%map.M a = hash ~init single_one and b = hash ~init triple_one in
        (a, b)
      in
      let%map.M c = hash ~init single_one and d = hash ~init triple_zero in
      (Field.add a c, Field.add b d)

    let%test "test6" =
      execute (comp6, [%test_eq: Field.t * Field.t] (two, one), 8, 2)

    let comp7 =
      let%map.M a, b =
        let%bind.M a = hash ~init single_one in
        let%map.M b = hash ~init triple_one in
        (a, b)
      and c = hash ~init single_one in
      (Field.add a c, b)

    let%test "test7" =
      execute (comp7, [%test_eq: Field.t * Field.t] (two, one), 5, 2)

    let comp8 =
      let%map.M c = hash ~init single_one
      and a, b =
        let%bind.M a = hash ~init single_one in
        let%map.M b = hash ~init triple_one in
        (a, b)
      in
      (Field.add a c, b)

    let%test "test8" =
      execute (comp8, [%test_eq: Field.t * Field.t] (two, one), 5, 2)

    let comp9 =
      let%map.M a, b =
        let%bind.M a = hash ~init single_one in
        let%map.M b = hash ~init triple_one in
        (a, b)
      and c, d =
        let%bind.M c = hash ~init single_one in
        let%map.M d = hash ~init triple_zero in
        (c, d)
      in
      (Field.add a c, Field.add b d)

    let double_comp c = c >>= const c

    let%test "test9" =
      execute (comp9, [%test_eq: Field.t * Field.t] (two, one), 8, 2)

    let comp10 =
      lift2 Tuple3.create
        (double_comp @@ hash ~init single_zero)
        (double_comp @@ hash ~init ten_zero)
      <*> double_comp @@ hash ~init triple_zero

    let%test "test10" =
      execute
        ( comp10
        , [%test_eq: Field.t * Field.t * Field.t] (zero, zero, zero)
        , 28
        , 2 )

    let comp11 =
      List.init 10 ~f:(const (single_one, triple_one, ten_zero))
      |> map_list ~f:(fun (a, b, c) ->
             lift2 Tuple3.create
               (double_comp @@ hash ~init a)
               (double_comp @@ hash ~init b)
             <*> double_comp @@ hash ~init c )

    let%test "test11" =
      execute
        ( comp11
        , [%test_eq: (Field.t * Field.t * Field.t) list]
            (List.init 10 ~f:(const (one, one, zero)))
        , 280
        , 2 )
  end )
