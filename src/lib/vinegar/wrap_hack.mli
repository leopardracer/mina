module Padded_length = Vinegar_types.Nat.N2

val pad_accumulator :
     (Backend.Tock.Proof.Challenge_polynomial.t, 'a) Vinegar_types.Vector.t
  -> ( Kimchi_pasta.Pallas_based_plonk.Proof.G.Affine.Stable.V1.t
     , Backend.Tock.Field.t )
     Backend.Tock.Proof.Challenge_polynomial.t_
     list

val hash_messages_for_next_wrap_proof :
     'n Vinegar_types.Nat.t
  -> ( Backend.Tick.Curve.Affine.t
     , ( ( Backend.Tock.Field.t
         , Vinegar_types.Nat.z Backend.Tock.Rounds.plus_n )
         Vinegar_types.Vector.t
       , 'n )
       Vinegar_types.Vector.t )
     Composition_types.Wrap.Proof_state.Messages_for_next_wrap_proof.t
  -> Import.Types.Digest.Constant.t

val pad_proof : ('mlmb, 'a) Proof.t -> Proof.Proofs_verified_max.t

val pad_challenges :
     ( ( Backend.Tock.Field.t
       , Vinegar_types.Nat.z Backend.Tock.Rounds.plus_n )
       Vinegar_types.Vector.t
     , 'a )
     Vinegar_types.Vector.t
  -> ( ( Backend.Tock.Field.t
       , Vinegar_types.Nat.z Backend.Tock.Rounds.plus_n )
       Vinegar_types.Vector.t
     , Vinegar_types.Nat.z Padded_length.plus_n )
     Vinegar_types.Vector.t

module Checked : sig
  val pad_challenges :
       ( ( Impls.Wrap.Field.t
         , Vinegar_types.Nat.z Backend.Tock.Rounds.plus_n )
         Vinegar_types.Vector.t
       , 'a )
       Vinegar_types.Vector.t
    -> ( ( Impls.Wrap.Field.t
         , Vinegar_types.Nat.z Backend.Tock.Rounds.plus_n )
         Vinegar_types.Vector.t
       , Vinegar_types.Nat.z Padded_length.plus_n )
       Vinegar_types.Vector.t

  val pad_commitments :
       (Impls.Step.Field.t Tuple_lib.Double.t, 'a) Vinegar_types.Vector.t
    -> ( Impls.Step.Field.t Tuple_lib.Double.t
       , Vinegar_types.Nat.z Padded_length.plus_n )
       Vinegar_types.Vector.t

  val dummy_messages_for_next_wrap_proof_sponge_states :
    ( Sponge.Poseidon(Tock_field_sponge.Inputs).Field.t Sponge.State.t
    * Sponge.sponge_state )
    array
    lazy_t

  val hash_constant_messages_for_next_wrap_proof :
       'a Vinegar_types.Nat.t
    -> ( Backend.Tick.Curve.Affine.t
       , ( ( Backend.Tock.Field.t
           , Vinegar_types.Nat.z Backend.Tock.Rounds.plus_n )
           Vinegar_types.Vector.t
         , 'a )
         Vinegar_types.Vector.t )
       Composition_types.Wrap.Proof_state.Messages_for_next_wrap_proof.t
    -> Import.Types.Digest.Constant.t

  val hash_messages_for_next_wrap_proof :
       'n Vinegar_types.Nat.t
    -> ( Wrap_main_inputs.Inner_curve.t
       , ( (Impls.Wrap.Field.t, Backend.Tock.Rounds.n) Vinegar_types.Vector.t
         , 'n )
         Vinegar_types.Vector.t )
       Composition_types.Wrap.Proof_state.Messages_for_next_wrap_proof.t
    -> Wrap_main_inputs.Sponge.Permutation.Field.t
end
