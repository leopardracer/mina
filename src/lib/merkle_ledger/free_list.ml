module type S = sig
  type t

  type location

  val equal : t -> t -> bool

  val sexp_of_t : t -> Sexp.t

  val t_of_sexp : Sexp.t -> t

  val serialize : ledger_depth:int -> t -> Bigstring.t

  val deserialize : ledger_depth:int -> Bigstring.t -> t

  val empty : t

  val size : t -> int

  val pp : Format.formatter -> t -> unit

  val gen : ledger_depth:int -> t Quickcheck.Generator.t

  module Location : sig
    val add : t -> location -> t

    val pop : t -> (location * t) option

    val top : t -> location option

    val mem : t -> location -> bool

    val remove_all_contiguous : t -> location -> t * location option
  end
end

module Make (L : Location_intf.S) : S with type location = L.t = struct
  module Addr = L.Addr

  type location = L.t

  include Set.Make (L.Addr)

  let size = length

  let pp ppf set =
    Format.fprintf ppf "@[<hov>[ %a]@]"
      (fun ppf set -> iter set ~f:(Format.fprintf ppf "%a;@ " Addr.pp))
      set

  (* [remove_all_contiguous set addr] removes all addresses contiguous from
     [a] in decreasing order according to {!val:Location.Addr.prev}.

     @return  a free list where all such addresses have been removed, and the first
     address not in set, if any
  *)
  let rec remove_all_contiguous set addr =
    if mem set addr then
      let set = remove set addr in
      let addr = Addr.prev addr in
      match addr with
      | None ->
          (set, addr)
      | Some addr ->
          remove_all_contiguous set addr
    else (set, Some addr)

  (* This could be made more efficient, especially if we stored the size of the
     set.

     We'd just have to allocate the bigstring of <size> * <addr size> and
     iterate once.

     Instead, iterate 3x (to_list, List.map, Bigstring.concat).
  *)
  let serialize ~ledger_depth t =
    to_list t |> List.map ~f:(Addr.serialize ~ledger_depth) |> Bigstring.concat

  (* [byte_count_of_bits n] returns how many bytes we need to represent [n] bits *)
  let byte_count_of_bits n = (n / 8) + min 1 (n % 8)

  (* [deserialize] *)
  let deserialize ~ledger_depth bs =
    let bitsize = byte_count_of_bits ledger_depth in
    let len = Bigstring.length bs in
    let rec read acc pos =
      if pos >= len then acc
      else
        let data = Bigstring.sub bs ~pos ~len:bitsize in
        let path = Addr.of_byte_string (Bigstring.to_string data) in
        let addr = Addr.slice path 0 ledger_depth in
        read (addr :: acc) (pos + bitsize)
    in
    let addrs = read [] 0 in
    of_list addrs

  let gen ~ledger_depth =
    let path_gen = Direction.gen_list ledger_depth in
    let addr_gen = Quickcheck.Generator.map path_gen ~f:Addr.of_directions in
    let addrs = Quickcheck.Generator.list addr_gen in
    Quickcheck.Generator.map addrs ~f:of_list

  module Location = struct
    (* The free list should only contain addresses that locate accounts *)
    let add set = function
      | L.Account addr ->
          add set addr
      | Generic _bigstring ->
          invalid_arg "Free_list.add_location: cannot add generic"
      | Hash _ ->
          invalid_arg "Free_list.add_location: cannot add hash"

    let account addr = L.Account addr

    let top = max_elt

    let pop set =
      Option.map ~f:(fun addr -> (account addr, remove set addr)) (top set)

    let top set = Option.map ~f:account (top set)

    let mem set = function
      | L.Account addr ->
          mem set addr
      | Generic _ | Hash _ ->
          false

    let remove_all_contiguous set = function
      | L.Account addr ->
          let set, addr = remove_all_contiguous set addr in
          (set, Option.map ~f:account addr)
      | Generic _bigstring ->
          invalid_arg "Free_list.add_location: cannot add generic"
      | Hash _ ->
          invalid_arg "Free_list.add_location: cannot add hash"
  end
end
