(** @param min_log2 defaults to 0 *)
val domains :
     ?min_log2:int
  -> (module Snarky_backendless.Snark_intf.Run with type field = 'field)
  -> ('a, 'b, 'field) Import.Spec.ETyp.t
  -> ('c, 'd, 'field) Import.Spec.ETyp.t
  -> ('a -> 'c)
  -> Import.Domains.t

val rough_domains : Import.Domains.t
