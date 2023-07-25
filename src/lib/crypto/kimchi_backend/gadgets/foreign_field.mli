module Bignum_bigint = Snarky_backendless.Backend_extended.Bignum_bigint
module Snark_intf = Snarky_backendless.Snark_intf

(** Conventions used
 *     1. Functions prefixed with "as_prover_" only happen during proving
 *        and not during circuit creation
 *     2. Functions suffixed with "_as_prover" can only be called outside
 *        the circuit.  Specifically, this means within an exists, within
 *        an as_prover or in an "as_prover_" prefixed function)
 *)

(** Foreign field modulus is abstract on two parameters
 *    Field type
 *    Limbs structure
 *
 *   There are 2 specific limb structures required
 *     Standard mode := 3 limbs of L-bits each
 *     Compact mode  := 2 limbs where the lowest is 2L bits and the highest is L bits
 *)
type 'field standard_limbs = 'field * 'field * 'field

type 'field compact_limbs = 'field * 'field

val bignum_bigint_to_field_const_standard_limbs :
     (module Snark_intf.Run with type field = 'field)
  -> Bignum_bigint.t
  -> 'field standard_limbs

val field_const_standard_limbs_to_bignum_bigint :
     (module Snark_intf.Run with type field = 'field)
  -> 'field standard_limbs
  -> Bignum_bigint.t

val check_modulus :
     (module Snark_intf.Run with type field = 'field)
  -> 'field standard_limbs
  -> unit

val check_modulus_bignum_bigint :
  (module Snark_intf.Run with type field = 'field) -> Bignum_bigint.t -> unit

(** Foreign field element base type - not used directly *)
module type Element_intf = sig
  type 'field t

  type 'a limbs_type

  module Cvar = Snarky_backendless.Cvar

  (** Create foreign field element from Cvar limbs *)
  val of_limbs : 'field Cvar.t limbs_type -> 'field t

  (** Create foreign field element from field limbs *)
  val of_field_limbs :
       (module Snark_intf.Run with type field = 'field)
    -> 'field limbs_type
    -> 'field t

  (** Create foreign field element from Bignum_bigint.t *)
  val of_bignum_bigint :
       (module Snark_intf.Run with type field = 'field)
    -> Bignum_bigint.t
    -> 'field t

  (** Create constant foreign field element from Bignum_bigint.t *)
  val const_of_bignum_bigint :
       (module Snark_intf.Run with type field = 'field)
    -> Bignum_bigint.t
    -> 'field t

  (** Convert foreign field element into Cvar limbs *)
  val to_limbs : 'field t -> 'field Cvar.t limbs_type

  (** Map foreign field element's Cvar limbs into some other limbs with the mapping function func *)
  val map : 'field t -> ('field Cvar.t -> 'g) -> 'g limbs_type

  (** One constant *)
  val one : (module Snark_intf.Run with type field = 'field) -> 'field t

  (** Convert foreign field element into field limbs *)
  val to_field_limbs_as_prover :
       (module Snark_intf.Run with type field = 'field)
    -> 'field t
    -> 'field limbs_type

  (** Convert foreign field element into Bignum_bigint.t limbs *)
  val to_bignum_bigint_limbs_as_prover :
       (module Snark_intf.Run with type field = 'field)
    -> 'field t
    -> Bignum_bigint.t limbs_type

  (** Convert foreign field element into a Bignum_bigint.t *)
  val to_bignum_bigint_as_prover :
       (module Snark_intf.Run with type field = 'field)
    -> 'field t
    -> Bignum_bigint.t

  (** Convert foreign field affine point to string *)
  val to_string_as_prover :
    (module Snark_intf.Run with type field = 'field) -> 'field t -> string

  (** Constrain zero check computation with boolean output *)
  val is_zero :
       (module Snark_intf.Run with type field = 'field)
    -> 'field t
    -> 'field Cvar.t Snark_intf.Boolean0.t

  (** Compare if two foreign field elements are equal *)
  val equal_as_prover :
       (module Snark_intf.Run with type field = 'field)
    -> 'field t
    -> 'field t
    -> bool

  (** Add copy constraints that two foreign field elements are equal *)
  val assert_equal :
       (module Snark_intf.Run with type field = 'field)
    -> 'field t
    -> 'field t
    -> unit

  (* Create and constrain foreign field element from Bignum_bigint.t *)
  val check_here_const_of_bignum_bigint :
       (module Snark_intf.Run with type field = 'field)
    -> Bignum_bigint.t
    -> 'field t

  (** Add conditional constraints to select foreign field element *)
  val if_ :
       (module Snark_intf.Run with type field = 'field)
    -> 'field Cvar.t Snark_intf.Boolean0.t
    -> then_:'field t
    -> else_:'field t
    -> 'field t

  (** Decompose and constrain foreign field element into list of boolean cvars *)
  val unpack :
       (module Snark_intf.Run with type field = 'field)
    -> 'field t
    -> length:int
    -> 'field Cvar.t Snark_intf.Boolean0.t list
end

module Element : sig
  (** Foreign field element type (standard limbs) *)
  module Standard : sig
    include Element_intf with type 'a limbs_type = 'a standard_limbs
  end
end

(** Context for tracking external checks that must be made
 *  (using other gadgets) in order to acheive soundess for a
 *  given multiplication
 *)
module External_checks : sig
  module Cvar = Snarky_backendless.Cvar

  type 'field t =
    { mutable bounds : ('field Cvar.t standard_limbs * bool) list
    ; mutable canonicals : 'field Cvar.t standard_limbs list
    ; mutable multi_ranges : 'field Cvar.t standard_limbs list
    ; mutable compact_multi_ranges : 'field Cvar.t compact_limbs list
    ; mutable limb_ranges : 'field Cvar.t list
    }

  (** Create a new context *)
  val create : (module Snark_intf.Run with type field = 'field) -> 'field t

  (** Track a bound check *)
  val append_bound_check :
    'field t -> ?do_multi_range_check:bool -> 'field Element.Standard.t -> unit

  (** Track a canonical check *)
  val append_canonical_check : 'field t -> 'field Element.Standard.t -> unit

  (** Track a multi-range-check *)
  val append_multi_range_check :
    'field t -> 'field Cvar.t standard_limbs -> unit

  (** Track a compact-multi-range-check *)
  val append_compact_multi_range_check :
    'field t -> 'field Cvar.t compact_limbs -> unit

  (** Tracks a limb-range-check *)
  val append_limb_check : 'field t -> 'field Cvar.t -> unit
end

(* Type of operation *)
type op_mode = Add | Sub

(** Bound check the supplied value
 *    Inputs:
 *      external_checks       := Context to track required external checks
 *      x                     := Value to check
 *      do_multi_range_check  := Whether to multi-range-check x
 *      foreign_field_modulus := Foreign field modulus
 *
 *    Outputs:
 *      Inserts generic gate to constrain computation of high bound x'2 = x2 + 2^88 - f2 - 1
 *      Adds x to external_checks.multi_ranges
 *      Adds x'2 to external_checks.limb_ranges
 *      Returns computed high bound
 *)
val check_bound :
     (module Snark_intf.Run with type field = 'f)
  -> 'f External_checks.t (* external_checks context *)
  -> 'f Element.Standard.t (* value *)
  -> bool (* do_multi_range_check *)
  -> 'f standard_limbs (* foreign_field_modulus *)
  -> 'f Snarky_backendless.Cvar.t
(* bound *)

(** Gadget to check the supplied value is a canonical foreign field element for the
 * supplied foreign field modulus
 *
 *    This gadget checks in the circuit that a value is less than the foreign field modulus.
 *    Part of this involves computing a bound value that is both added to external_checks
 *    and also returned.  The caller may use either one, depending on the situation.
 *
 *    Inputs:
 *      external_checks       := Context to track required external checks
 *      value                 := Value to check
 *      foreign_field_modulus := Foreign field modulus
 *
 *    Outputs:
 *      Inserts ForeignFieldAdd gate
 *      Inserts Zero gate containing result
 *      Adds bound to be multi-range-checked to external_checks
 *      Returns bound value
 *)
val check_canonical :
     (module Snark_intf.Run with type field = 'f)
  -> 'f External_checks.t (* external_checks context *)
  -> 'f Element.Standard.t (* value *)
  -> 'f standard_limbs (* foreign_field_modulus *)
  -> 'f Element.Standard.t
(* result *)

(** Gadget to constrain external checks using supplied modulus *)
val constrain_external_checks :
     (module Snark_intf.Run with type field = 'f)
  -> 'f External_checks.t
  -> 'f standard_limbs
  -> unit

(** Gadget for a chain of foreign field sums (additions or subtractions)
 *
 *    Inputs:
 *      inputs                := All the inputs to the chain of sums
 *      operations            := List of operation modes Add or Sub indicating whether the
 *                               corresponding addition is a subtraction
 *      foreign_field_modulus := Foreign field modulus
 *
 *    Outputs:
 *      Inserts ForeignFieldAdd gate into the circuit
 *      Returns the final result of the chain of sums
 *
 *    For n+1 inputs, the gadget creates n foreign field addition gates.
 *)
val sum_chain :
     (module Snark_intf.Run with type field = 'f)
  -> 'f Element.Standard.t list (* inputs *)
  -> op_mode list (* operations *)
  -> 'f standard_limbs (* foreign_field_modulus *)
  -> 'f Element.Standard.t
(* result *)

(** Gadget for a single foreign field addition
 *
 *    Inputs:
 *      left_input            := Foreign field element
 *      right_input           := Foreign field element
 *      foreign_field_modulus := Foreign field modulus
 *
 *    Outputs:
 *      Inserts ForeignFieldAdd gate into the circuit
 *      Returns the result
 *)
val add :
     (module Snark_intf.Run with type field = 'f)
  -> 'f Element.Standard.t (* left_input *)
  -> 'f Element.Standard.t (* right_input *)
  -> 'f standard_limbs (* foreign_field_modulus *)
  -> 'f Element.Standard.t
(* result *)

(** Gadget for a single foreign field subtraction
 *
 *    Inputs:
 *      left_input            := Foreign field element
 *      right_input           := Foreign field element
 *      foreign_field_modulus := Foreign field modulus
 *
 *    Outputs:
 *      Inserts ForeignFieldAdd gate into the circuit
 *      Returns ther result
 *)
val sub :
     (module Snark_intf.Run with type field = 'f)
  -> 'f Element.Standard.t (* left_input *)
  -> 'f Element.Standard.t (* right_input *)
  -> 'f standard_limbs (* foreign_field_modulus *)
  -> 'f Element.Standard.t
(* result *)

(** Gadget for creating an addition or subtraction result row (Zero gate with result) *)
val result_row :
     (module Snark_intf.Run with type field = 'f)
  -> ?label:string
  -> 'f Element.Standard.t
  -> 'f Element.Standard.t option
  -> unit

(** Gadget for foreign field multiplication
 *
 *   Constrains that
 *
 *     left_input * right_input = quotient * foreign_field_modulus + remainder
 *
 *   where remainder is the product.
 *
 *   Inputs:
 *     external_checks       := Context to track required external checks
 *     left_input            := Multiplicand foreign field element
 *     right_input           := Multiplicand foreign field element
 *     foreign_field_modulus := Must be less than than max foreign field modulus
 *
 *   Outputs:
 *     Inserts the ForeignFieldMul gate, followed by Zero gate into the circuit
 *     Appends required values to external_checks
 *     Returns the product
 *)
val mul :
     (module Snark_intf.Run with type field = 'f)
  -> 'f External_checks.t (* external_checks *)
  -> 'f Element.Standard.t (* left_input *)
  -> 'f Element.Standard.t (* right_input *)
  -> 'f standard_limbs (* foreign_field_modulus *)
  -> 'f Element.Standard.t
(* remainder *)

(** Gadget to constrain conversion of bytes list (e.g. output of Keccak gadget)
 *  into a foreign field element (e.g. input of ECDSA gadget).
 *
 *  Parameters: endianness of the bytes list
 *)
val bytes_to_standard_element :
     (module Snark_intf.Run with type field = 'f)
  -> endian:Keccak.endianness
  -> 'f Snarky_backendless.Cvar.t list
  -> 'f standard_limbs
  -> int
  -> 'f Element.Standard.t
