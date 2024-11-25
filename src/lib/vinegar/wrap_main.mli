open Vinegar_types

(** [wrap_main] is the SNARK function for wrapping any proof coming from the given set of
    keys **)
val wrap_main :
     num_chunks:int
  -> feature_flags:Opt.Flag.t Plonk_types.Features.Full.t
  -> ( 'max_proofs_verified
     , 'branches
     , 'max_local_max_proofs_verifieds )
     Full_signature.t
  -> ('prev_varss, 'branches) Vinegar_types.Hlist.Length.t
  -> ( ( Wrap_main_inputs.Inner_curve.Constant.t array
       (* commitments *)
       , Wrap_main_inputs.Inner_curve.Constant.t array option
       (* commitments to optional gates *) )
       Wrap_verifier.index'
     , 'branches )
     Vinegar_types.Vector.t
     Promise.t
     Lazy.t
     (* All the commitments, include commitments to optional gates, saved in a
        vector of size ['branches] *)
  -> (int, 'branches) Vinegar_types.Vector.t
  -> (Import.Domains.t, 'branches) Vinegar_types.Vector.t Promise.t
  -> srs:Kimchi_bindings.Protocol.SRS.Fp.t
  -> (module Vinegar_types.Nat.Add.Intf with type n = 'max_proofs_verified)
  -> ('max_proofs_verified, 'max_local_max_proofs_verifieds) Requests.Wrap.t
     * (   ( Wrap_main_inputs.Impl.Field.t
           , Wrap_verifier.Scalar_challenge.t
           , Wrap_verifier.Other_field.Packed.t
             Vinegar_types.Shifted_value.Type1.t
           , ( Wrap_verifier.Other_field.Packed.t
               Vinegar_types.Shifted_value.Type1.t
             , Wrap_main_inputs.Impl.Boolean.var )
             Vinegar_types.Opt.t
           , ( Wrap_verifier.Scalar_challenge.t
             , Wrap_main_inputs.Impl.Boolean.var )
             Vinegar_types.Opt.t
           , Impls.Wrap.Boolean.var
           , Impls.Wrap.Field.t
           , Impls.Wrap.Field.t
           , Impls.Wrap.Field.t
           , ( Impls.Wrap.Field.t Import.Scalar_challenge.t
               Import.Types.Bulletproof_challenge.t
             , 'c )
             Vinegar_types.Vector.t
           , Wrap_main_inputs.Impl.Field.t )
           Import.Types.Wrap.Statement.In_circuit.t
        -> unit )
       Promise.t
       Lazy.t
