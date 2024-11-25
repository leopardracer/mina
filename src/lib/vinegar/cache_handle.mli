(** Cache handle. It is currently used to cache proving and verifying keys for vinegar *)

type t = Dirty.t Promise.t Lazy.t

(** [generate_or_load hdl] is an alias for [Lazy.force]. *)
val generate_or_load : t -> Dirty.t Promise.t

(** [(+)] is semantically equivalent to {!Dirty.(+)}. *)
val ( + ) : t -> t -> t
