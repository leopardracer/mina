open Core
open Async
open Integration_test_lib
open Mina_base

module Make (Inputs : Intf.Test.Inputs_intf) = struct
  open Inputs
  open Engine
  open Dsl

  open Test_common.Make (Inputs)

  type network = Network.t

  type node = Network.Node.t

  type dsl = Dsl.t

  let config =
    let open Test_config in
    { default with
      requires_graphql = true
    ; genesis_ledger =
        [ { account_name = "node-a-key"
          ; balance = "8000000000"
          ; timing = Untimed
          }
        ; { account_name = "node-b-key"; balance = "1000000"; timing = Untimed }
        ; { account_name = "fish1"; balance = "3000"; timing = Untimed }
        ; { account_name = "fish2"; balance = "3000"; timing = Untimed }
        ; { account_name = "snark-node-key"; balance = "0"; timing = Untimed }
        ]
    ; block_producers =
        [ { node_name = "node-a"; account_name = "node-a-key" }
        ; { node_name = "node-b"; account_name = "node-b-key" }
        ]
    ; num_archive_nodes = 1
    ; snark_coordinator =
        Some
          { node_name = "snark-node"
          ; account_name = "snark-node-key"
          ; worker_nodes = 8
          }
    ; snark_worker_fee = "0.0001"
    ; proof_config =
        { proof_config_default with
          work_delay = Some 1
        ; transaction_capacity =
            Some Runtime_config.Proof_keys.Transaction_capacity.medium
        }
    }

  let transactions_sent = ref 0

  let num_proofs = 2

  let blocks_for_first_proof_exn =
    Test_config.blocks_for_first_ledger_proof_exn config

  let padding_payments () =
    let needed_for_padding =
      Test_config.transactions_needed_for_ledger_proofs config ~num_proofs
    in
    if !transactions_sent >= needed_for_padding then 0
    else needed_for_padding - !transactions_sent

  let send_zkapp ~logger node zkapp_command =
    incr transactions_sent ;
    send_zkapp ~logger node zkapp_command

  (* Call [f] [n] times in sequence *)
  let repeat_seq ~n ~f =
    let open Malleable_error.Let_syntax in
    let rec go n =
      if n = 0 then return ()
      else
        let%bind () = f () in
        go (n - 1)
    in
    go n

  let send_padding_transactions ~fee ~logger ~n nodes =
    let sender = List.nth_exn nodes 0 in
    let receiver = List.nth_exn nodes 1 in
    let open Malleable_error.Let_syntax in
    let%bind sender_pub_key = pub_key_of_node sender in
    let%bind receiver_pub_key = pub_key_of_node receiver in
    repeat_seq ~n ~f:(fun () ->
        Network.Node.must_send_payment ~logger sender ~sender_pub_key
          ~receiver_pub_key ~amount:Currency.Amount.one ~fee
        >>| ignore )

  let run network t =
    let open Malleable_error.Let_syntax in
    let logger = Logger.create () in
    let block_producer_nodes =
      Network.block_producers network |> Core.String.Map.data
    in
    let node =
      Core.String.Map.find_exn (Network.block_producers network) "node-a"
    in
    let fish1_kp =
      (Core.String.Map.find_exn (Network.genesis_keypairs network) "fish1")
        .keypair
    in
    let fish1_pk = Signature_lib.Public_key.compress fish1_kp.public_key in
    let fish1_account_id =
      Mina_base.Account_id.create fish1_pk Mina_base.Token_id.default
    in
    let with_timeout ~soft_slots =
      let soft_timeout = Network_time_span.Slots soft_slots in
      let hard_timeout = Network_time_span.Slots (soft_slots * 2) in
      Wait_condition.with_timeouts ~soft_timeout ~hard_timeout
    in
    let wait_for_zkapp ~has_failures zkapp_command =
      let%map () =
        wait_for t @@ with_timeout ~soft_slots:4
        @@ Wait_condition.zkapp_to_be_included_in_frontier ~has_failures
             ~zkapp_command
      in
      [%log info] "zkApp transaction included in transition frontier"
    in
    (*Wait for first BP to start sending payments and avoid partially filling blocks*)
    let first_bp = List.hd_exn block_producer_nodes in
    let%bind () =
      wait_for t (Wait_condition.nodes_to_initialize [ first_bp ])
    in
    (*Start sending padding transactions to get snarked ledger sooner*)
    let%bind () =
      let fee = Currency.Fee.of_nanomina_int_exn 3_000_000 in
      send_padding_transactions block_producer_nodes ~fee ~logger
        ~n:(padding_payments ())
    in
    (*wait for the rest*)
    let%bind () =
      wait_for t
        (Wait_condition.nodes_to_initialize
           (List.filter
              ~f:(fun n ->
                String.(Network.Node.id n <> Network.Node.id first_bp) )
              (Core.String.Map.data (Network.all_nodes network)) ) )
    in
    let keymap =
      List.fold [ fish1_kp ] ~init:Signature_lib.Public_key.Compressed.Map.empty
        ~f:(fun map { private_key; public_key } ->
          Signature_lib.Public_key.Compressed.Map.add_exn map
            ~key:(Signature_lib.Public_key.compress public_key)
            ~data:private_key )
    in
    let%bind.Deferred invalid_nonce_zkapp_cmd_from_fish1 =
      let open Zkapp_command_builder in
      let with_dummy_signatures =
        let account_updates =
          mk_forest
            [ mk_node
                (mk_account_update_body Signature No fish1_kp Token_id.default 0
                   ~preconditions:
                     { Account_update.Preconditions.network =
                         Zkapp_precondition.Protocol_state.accept
                     ; account = Nonce (Account.Nonce.of_int 1)
                     ; valid_while = Ignore
                     } )
                []
            ]
        in
        account_updates
        |> mk_zkapp_command ~memo:"invalid zkapp from fish1" ~fee:12_000_000
             ~fee_payer_pk:fish1_pk ~fee_payer_nonce:(Account.Nonce.of_int 0)
      in
      replace_authorizations ~keymap with_dummy_signatures
    in
    let%bind.Deferred valid_zkapp_cmd_from_fish1 =
      let open Zkapp_command_builder in
      let with_dummy_signatures =
        let account_updates =
          mk_forest
            [ mk_node
                (mk_account_update_body Signature No fish1_kp Token_id.default 0
                   ~preconditions:
                     { Account_update.Preconditions.network =
                         Zkapp_precondition.Protocol_state.accept
                     ; account = Nonce (Account.Nonce.of_int 2)
                     ; valid_while = Ignore
                     } )
                []
            ]
        in
        account_updates
        |> mk_zkapp_command ~memo:"valid zkapp from fish1" ~fee:12_000_000
             ~fee_payer_pk:fish1_pk ~fee_payer_nonce:(Account.Nonce.of_int 1)
      in
      replace_authorizations ~keymap with_dummy_signatures
    in
    let%bind.Deferred set_permission_zkapp_cmd_from_fish1 =
      let open Zkapp_command_builder in
      let with_dummy_signatures =
        let account_updates =
          mk_forest
            [ mk_node
                (mk_account_update_body Signature No fish1_kp Token_id.default 0
                   ~update:
                     { Account_update.Update.dummy with
                       permissions =
                         Set { Permissions.user_default with send = Proof }
                     } )
                []
            ]
        in
        account_updates
        |> mk_zkapp_command ~memo:"precondition zkapp from fish1"
             ~fee:12_000_000 ~fee_payer_pk:fish1_pk
             ~fee_payer_nonce:(Account.Nonce.of_int 2)
      in
      replace_authorizations ~keymap with_dummy_signatures
    in
    let%bind.Deferred valid_fee_invalid_permission_zkapp_cmd_from_fish1 =
      let open Zkapp_command_builder in
      let with_dummy_signatures =
        let account_updates =
          mk_forest
            [ mk_node
                (mk_account_update_body Signature No fish1_kp Token_id.default 1
                   ~increment_nonce:true )
                []
            ; mk_node
                (mk_account_update_body Signature No fish1_kp Token_id.default
                   (-1) )
                []
            ]
        in
        account_updates
        |> mk_zkapp_command ~memo:"valid zkapp from fish1" ~fee:12_000_000
             ~fee_payer_pk:fish1_pk ~fee_payer_nonce:(Account.Nonce.of_int 3)
      in
      replace_authorizations ~keymap with_dummy_signatures
    in
    let%bind.Deferred invalid_fee_invalid_permission_zkapp_cmd_from_fish1 =
      let open Zkapp_command_builder in
      let with_dummy_signatures =
        let account_updates =
          mk_forest
            [ mk_node
                (mk_account_update_body Signature No fish1_kp Token_id.default 0)
                []
            ]
        in
        account_updates
        |> mk_zkapp_command ~memo:"valid zkapp from fish1" ~fee:2_000_000
             ~fee_payer_pk:fish1_pk ~fee_payer_nonce:(Account.Nonce.of_int 4)
      in
      replace_authorizations ~keymap with_dummy_signatures
    in
    let snark_work_event_subscription =
      Event_router.on (event_router t) Snark_work_gossip ~f:(fun _ _ ->
          [%log info] "Received new snark work" ;
          Deferred.return `Continue )
    in
    let snark_work_failure_subscription =
      Event_router.on (event_router t) Snark_work_failed ~f:(fun _ _ ->
          [%log error]
            "A snark worker encountered an error while creating a proof" ;
          Deferred.return `Continue )
    in
    let%bind () =
      section_hard
        "Send a zkapp command with an invalid account update nonce using fish1"
        (send_zkapp ~logger node invalid_nonce_zkapp_cmd_from_fish1)
    in
    let%bind () =
      section_hard
        "Send a zkapp command that has its nonce properly incremented after \
         the fish1 transaction"
        (send_zkapp ~logger node valid_zkapp_cmd_from_fish1)
    in
    let%bind () =
      section_hard
        "Wait for fish1 zkapp command with invalid nonce to appear in \
         transition frontier with failed status"
        (wait_for_zkapp ~has_failures:true invalid_nonce_zkapp_cmd_from_fish1)
    in
    let%bind () =
      section_hard
        "Wait for fish1 zkapp command with valid nonce to be accepted into \
         transition frontier"
        (wait_for_zkapp ~has_failures:false valid_zkapp_cmd_from_fish1)
    in
    let%bind () =
      section_hard
        "Send a zkapp command account update for fish1 that sets send \
         permission to Proof"
        (send_zkapp ~logger node set_permission_zkapp_cmd_from_fish1)
    in
    let%bind () =
      section_hard
        "Send a zkapp command that should be valid after permission from the \
         fish1 transaction"
        (send_zkapp ~logger node
           valid_fee_invalid_permission_zkapp_cmd_from_fish1 )
    in
    (*low fee transaction to prevent from getting into a block*)
    let%bind () =
      section_hard
        "Send a zkapp command that should be invalid after permission from the \
         fish1 transaction is set to Proof"
        (send_zkapp ~logger node
           invalid_fee_invalid_permission_zkapp_cmd_from_fish1 )
    in
    let%bind () =
      section_hard
        "Wait for fish1 zkapp command with set permission to be accepted by \
         transition frontier"
        (wait_for_zkapp ~has_failures:false set_permission_zkapp_cmd_from_fish1)
    in
    let%bind () =
      section_hard
        "Wait for fish1 zkapp command to be accepted by transition frontier"
        (wait_for_zkapp ~has_failures:true
           valid_fee_invalid_permission_zkapp_cmd_from_fish1 )
    in
    let%bind () =
      section_hard
        "Verify account update after the updated permission failed by checking \
         account nonce"
        (let%bind { nonce = fish1_nonce; _ } =
           Network.Node.get_account_data ~logger node
             ~account_id:fish1_account_id
           |> Deferred.bind ~f:Malleable_error.or_hard_error
         in
         if Unsigned.UInt32.compare fish1_nonce (Unsigned.UInt32.of_int 4) > 0
         then
           Malleable_error.hard_error
             (Error.of_string
                "Nonce value of fish1 does not match expected nonce" )
         else (
           [%log info] "Invalid zkapp command was correctly ignored" ;
           return () ) )
    in
    (*TODO: enable later
      let%bind () =
        section_hard
          "Verify invalid zkapp commands are removed from transaction pool"
          (let%bind pooled_zkapp_commands =
             Network.Node.get_pooled_zkapp_commands ~logger node ~pk:fish1_pk
             |> Deferred.bind ~f:Malleable_error.or_hard_error
           in
           [%log debug] "Pooled zkapp_commands $commands"
             ~metadata:
               [ ( "commands"
                 , `List (List.map ~f:(fun s -> `String s) pooled_zkapp_commands)
                 )
               ] ;
           if List.is_empty pooled_zkapp_commands then (
             [%log info] "Transaction pool is empty" ;
             return () )
           else
             Malleable_error.hard_error
               (Error.of_string
                  "Transaction pool contains invalid zkapp commands after a \
                   block was produced" ) )
      in *)
    let%bind () =
      (*wait for blocks required to produce 2 proofs given 0.75 slot fill rate*)
      let soft_timeout =
        Network_time_span.Slots
          (Test_config.slots_of_blocks (blocks_for_first_proof_exn + 1))
      in
      let hard_timeout =
        Network_time_span.Slots
          (Test_config.slots_of_blocks (blocks_for_first_proof_exn + 4))
      in
      section_hard "Wait for proof to be emitted"
        ( wait_for t
        @@ Wait_condition.ledger_proofs_emitted_since_genesis ~soft_timeout
             ~hard_timeout ~num_proofs )
    in
    Event_router.cancel (event_router t) snark_work_event_subscription () ;
    Event_router.cancel (event_router t) snark_work_failure_subscription () ;
    section_hard "Running replayer"
      (let%bind logs =
         Network.Node.run_replayer ~logger
           ( List.hd_exn
           @@ (Network.archive_nodes network |> Core.String.Map.data) )
       in
       check_replayer_logs ~logger logs )
end
