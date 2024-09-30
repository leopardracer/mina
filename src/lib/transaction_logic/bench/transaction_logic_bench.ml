open Core_kernel
open Core_bench
open Mina_base

let mk_tx ~(constraint_constants : Genesis_constants.Constraint_constants.t)
    keypair nonce =
  let nonce = Unsigned.UInt32.of_int nonce in
  let num_acc_updates = 8 in
  let multispec : Transaction_snark.For_tests.Multiple_transfers_spec.t =
    let fee_payer = None in
    let generated_values =
      let open Base_quickcheck.Generator.Let_syntax in
      Base_quickcheck.Generator.list_with_length ~length:num_acc_updates
      @@ let%map kp = Signature_lib.Keypair.gen in
         (Signature_lib.Public_key.compress kp.public_key, Currency.Amount.zero)
    in
    let receivers =
      Quickcheck.random_value
        ~seed:(`Deterministic ("test-apply-" ^ Unsigned.UInt32.to_string nonce))
        generated_values
    in
    let zkapp_account_keypairs = [] in
    let new_zkapp_account = false in
    let snapp_update = Account_update.Update.dummy in
    let call_data = Snark_params.Tick.Field.zero in
    let preconditions = Some Account_update.Preconditions.accept in
    { fee = Currency.Fee.of_mina_int_exn 1
    ; sender = (keypair, nonce)
    ; fee_payer
    ; receivers
    ; amount =
        Currency.Amount.(
          scale
            (of_fee constraint_constants.account_creation_fee)
            num_acc_updates)
        |> Option.value_exn ~here:[%here]
    ; zkapp_account_keypairs
    ; memo = Signed_command_memo.empty
    ; new_zkapp_account
    ; snapp_update
    ; actions = []
    ; events = []
    ; call_data
    ; preconditions
    }
  in
  User_command.Zkapp_command
    (Transaction_snark.For_tests.multiple_transfers ~constraint_constants
       multispec )

module Logic =
  Mina_transaction_logic.Make (Mina_ledger_test_helpers.Ledger_helpers.Ledger)

let () =
  let kp =
    Quickcheck.random_value ~seed:(`Deterministic "kp")
      Signature_lib.Keypair.gen
  in
  let tx =
    mk_tx ~constraint_constants:Genesis_constants.Compiled.constraint_constants
      kp 1
  in
  let precompute_parallel n () =
    let open Random_oracle.Monad in
    evaluate
    @@ map_list ~f:Logic.precompute_transaction_hashes_m
         (List.init n ~f:(const tx))
  in
  let precompute_serial n () =
    List.init n ~f:(fun _ -> Logic.precompute_transaction_hashes tx)
  in
  let precompute_chunked ~chunk n () =
    let chunks = (n / chunk) + min 1 (n % chunk) in
    List.init chunks ~f:(fun i ->
        let m = if i = chunks - 1 then n % chunk else 0 in
        let m = if m = 0 then chunk else m in
        let open Random_oracle.Monad in
        evaluate
        @@ map_list ~f:Logic.precompute_transaction_hashes_m
             (List.init m ~f:(const tx)) )
  in
  let precompute_parallel_async ?how n () =
    printf "==== Running parallel async =====\n" ;
    Async.Thread_safe.block_on_async_exn
    @@ fun () ->
    let open Random_oracle.Monad in
    evaluate_async ~when_finished:Take_the_async_lock ?how
    @@ map_list ~f:Logic.precompute_transaction_hashes_m
         (List.init n ~f:(const tx))
  in
  let precompute_group n =
    Bench.Test.create_group
      ~name:(sprintf "precompute %d txs" n)
      [ Bench.Test.create ~name:"parallel" (precompute_parallel n)
        (* ; Bench.Test.create ~name:"parallel-async" (precompute_parallel_async n) *)
      ; Bench.Test.create ~name:"parallel-async-alt"
          (precompute_parallel_async ~how:`Alternating n)
        (* ; Bench.Test.create ~name:"chunked-128" (precompute_chunked ~chunk:128 n)
           ; Bench.Test.create ~name:"serial" (precompute_serial n) *)
        (* ; Bench.Test.create ~name:"parallel-async-3"
               (precompute_parallel_async ~how:(`Max_concurrent_jobs 3) n)
           ; Bench.Test.create ~name:"parallel-async-2"
               (precompute_parallel_async ~how:(`Max_concurrent_jobs 2) n)
           ; Bench.Test.create ~name:"chunked-128" (precompute_chunked ~chunk:128 n)
           ; Bench.Test.create ~name:"chunked-128-async"
               (precompute_chunked_async ~chunk:128 ~how:`Parallel n)
           ; Bench.Test.create ~name:"chunked-128-async-3"
               (precompute_chunked_async ~chunk:128 ~how:(`Max_concurrent_jobs 3) n)
           ; Bench.Test.create ~name:"chunked-128-async-2"
               (precompute_chunked_async ~chunk:128 ~how:(`Max_concurrent_jobs 2) n) *)
      ]
  in

  Core.Command.run @@ Bench.make_command
  @@ List.map ~f:precompute_group [ 2560 ]
