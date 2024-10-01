open Core_kernel
open Mina_base
open Mina_state
module Body = Staged_ledger_diff.Body
module Header = Header
module Validation = Validation
module Validated = Validated_block
module Precomputed = Precomputed_block
module Internal_transition = Internal_transition

type fully_invalid_block = Validation.fully_invalid_with_block

type initial_valid_block = Validation.initial_valid_with_block

type initial_valid_header = Validation.initial_valid_with_header

type almost_valid_block = Validation.almost_valid_with_block

type almost_valid_header = Validation.almost_valid_with_header

type fully_valid_block = Validation.fully_valid_with_block

let genesis ~precomputed_values : Block.with_hash * Validation.fully_valid =
  let genesis_state =
    Precomputed_values.genesis_state_with_hashes precomputed_values
  in
  let protocol_state = With_hash.data genesis_state in
  let block_with_hash =
    let body = Staged_ledger_diff.Body.create Staged_ledger_diff.empty_diff in
    let header =
      Header.create ~protocol_state
        ~protocol_state_proof:(Lazy.force Proof.blockchain_dummy)
        ~delta_block_chain_proof:
          (Protocol_state.previous_state_hash protocol_state, [])
        ()
    in
    let block = Block.create ~header ~body in
    With_hash.map genesis_state ~f:(Fn.const block)
  in
  let validation =
    ( (`Time_received, Truth.True ())
    , (`Genesis_state, Truth.True ())
    , (`Proof, Truth.True ())
    , ( `Delta_block_chain
      , Truth.True
          ( Mina_stdlib.Nonempty_list.singleton
          @@ Protocol_state.previous_state_hash protocol_state ) )
    , (`Frontier_dependencies, Truth.True ())
    , (`Staged_ledger_diff, Truth.True ())
    , (`Protocol_versions, Truth.True ()) )
  in
  (block_with_hash, validation)

  let genesis_header ~precomputed_values =
    let b, v = genesis ~precomputed_values in
    (With_hash.map ~f:Block.header b, v)
  
  let handle_dropped_transition ?pipe_name ~valid_cbs ~logger state_hash =
    [%log warn] "Dropping state_hash $state_hash from $pipe transition pipe"
      ~metadata:
        [ ("state_hash", State_hash.to_yojson state_hash)
        ; ("pipe", `String (Option.value pipe_name ~default:"an unknown"))
        ] ;
    List.iter
      ~f:(Fn.flip Mina_net2.Validation_callback.fire_if_not_already_fired `Reject)
      valid_cbs

let blockchain_length block = block |> Block.header |> Header.blockchain_length

let consensus_state =
  Fn.compose Protocol_state.consensus_state
    (Fn.compose Header.protocol_state Block.header)

    let strip_headers_from_chain_proof (init_st, body_hashes, headers) =
      let compute_hashes =
        Fn.compose Mina_state.Protocol_state.hashes Header.protocol_state
      in
      let body_hashes' =
        List.map headers
          ~f:(State_hash.With_state_hashes.state_body_hash ~compute_hashes)
      in
      (init_st, body_hashes @ body_hashes')

include Block
