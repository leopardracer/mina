let () =
  Alcotest.run "Pickles"
    ( Test_wrap_hack.tests @ Test_opt_sponge.tests @ Test_scalar_challenge.tests
    @ Test_side_loaded_verification_key.tests @ Test_impls.tests
    @ Test_sponge.tests @ Test_step.tests @ Test_plonk_curve_ops.tests
    @ Test_wrap.tests @ Test_step_verifier.tests @ Test_pickles.tests )
