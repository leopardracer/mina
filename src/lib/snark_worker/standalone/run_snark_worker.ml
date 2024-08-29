open Core_kernel
open Async
module Prod = Snark_worker__Prod.Inputs

let command =
  let open Command.Let_syntax in
  Command.async ~summary:"Run snark worker directly"
    (let%map_open spec =
       flag "--spec-sexp" ~doc:""
         (required (sexp_conv Prod.single_spec_of_sexp))
     and network_constants =
       flag "--network"
         ~doc:
           "mainnet|testnet|lightnet|dev Set the configuration base according \
            to the network"
         (required
            (Command.Arg_type.of_alist_exn
               [ ("mainnet", Runtime_config.Network_constants.mainnet)
               ; ("devnet", Runtime_config.Network_constants.devnet)
               ; ("lightnet", Runtime_config.Network_constants.lightnet)
               ; ("dev", Runtime_config.Network_constants.dev)
               ] ) )
     and proof_level =
       flag "--proof-level" ~doc:""
         (optional_with_default Genesis_constants.Proof_level.Full
            (Command.Arg_type.of_alist_exn
               [ ("Full", Genesis_constants.Proof_level.Full)
               ; ("Check", Check)
               ; ("None", None)
               ] ) )
     in
     fun () ->
       let open Async in
       let constraint_constants =
         { (Genesis_constants.Constraint_constants.make
              network_constants.constraint_constants )
           with
           proof_level
         }
       in
       let%bind worker_state =
         Prod.Worker_state.create ~constraint_constants ~proof_level ()
       in
       let public_key = fst Key_gen.Sample_keypairs.genesis_winner in
       let fee = Currency.Fee.of_nanomina_int_exn 10 in
       let message = Mina_base.Sok_message.create ~fee ~prover:public_key in
       match%bind Prod.perform_single worker_state ~message spec with
       | Ok (proof, time) ->
           Caml.Format.printf
             !"@[<v>Successfully proved in %{sexp: Time.Span.t}.@,\
               Proof was:@,\
               %{sexp: Transaction_snark.t}@]@."
             time proof ;
           exit 0
       | Error err ->
           Caml.Format.printf
             !"Proving failed with error: %s@."
             (Error.to_string_hum err) ;
           exit 1 )

let () = Command.run command
